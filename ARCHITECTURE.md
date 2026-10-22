# Architecture

keryx is a small command line program. Every command reads and writes the mailboxes on disk and
exits, except `keryx courier`, which a machine may keep running to forward mail and ring again.
No command depends on it being there. This page describes each piece and the rules it follows.

## The store

All state lives under one directory, `$KERYX_HOME` or `$XDG_STATE_HOME/keryx`.

```text
addresses/NAME/address.json    the address: its role and when it was created
addresses/NAME/occupant.json   the session holding it, while one does
addresses/NAME/tmp/            messages being written
addresses/NAME/mail/           every message, under its id, never moved
addresses/NAME/read/           a hard link for each message read
addresses/NAME/receipts/       bell results and hook reminders, one file per message
occupants.lock                 locked while a command changes which session holds an address
outbox/HOST/new/               messages waiting to go to another machine
outbox/HOST/cur/               messages the other machine took
outbox/HOST/refused/           messages the other machine refused
outbox/HOST/receipts/          forwarding attempts and outcomes, one file each per message
```

A message is one JSON file named after its id. It is written whole under `tmp/`, synced, and then
linked into `mail/`. Linking is atomic, so a reader never sees half a message, and it fails when the
name already exists. Since a message never leaves `mail/`, delivering it again stores it once even
after it was read. Reading a message links it into `read/`, and the unread messages are the names in
`mail/` missing from `read/`, found without opening the files that were read.

Nothing else records state. A request is answered when some mailbox holds a reply from its
recipient, in its thread, whose `in_reply_to` is the request's id; it is read when its name is in
`read/`. Because no mail operation has to change two files together, mail takes no locks and a
crash leaves nothing half done. Only a change of occupants takes a lock, as the next section
explains.

Message ids are [ULIDs](https://github.com/ulid/spec), 26 characters that sort by creation time,
so a directory listing is already in order.

`Store` and `Outbox` are the only code that touches these paths, and they validate every address
and host name before building a path from it.

## Identity

A command first works out which session called it (`Caller`), from what the harness exports to
the commands it runs.

- Claude Code sets `CLAUDECODE`, `CLAUDE_PID`, `CLAUDE_CODE_SESSION_ID` and
  `CLAUDE_CODE_MESSAGING_SOCKET`.
- Codex sets `CODEX_THREAD_ID`.
- Cursor sets `CURSOR_CONVERSATION_ID`.
- herdr sets `HERDR_SOCKET_PATH` and `HERDR_PANE_ID` in its panes, and answers which agent runs in
  a pane.

A harness started from another harness's shell inherits the outer one's variables, so keryx reads
Cursor's and Codex's before Claude Code's.

`keryx join` writes these down as the address's occupant. Later commands find their address by
matching the caller against the occupants (`Identity`), which means the same Claude Code process
or session, the same Codex thread or Cursor conversation, or the same harness in the same herdr
pane. The pane rule lets a session restarted in its pane keep its address, and `App#me` then
records the new process and socket.

A session holds one address, so join also releases any other address the session holds. It checks
the address, releases the others and writes the occupant under an exclusive `flock` on
`occupants.lock`, so two joins that run at once, of one session or of two, take turns. The kernel
drops the lock when a process ends, so a crash never leaves it held, but the lock does not make
those writes one transaction, and a join cut off between releasing and writing leaves the session
with no address until it joins again. `App#me` records a new process or socket under the same lock,
from the occupant it reads again there, so it never writes back an address a join released. `leave`
finds the session's address and removes it under the lock too, so a refresh cannot write it back
and the occupant of a session that took the address over in between is never removed.

A join or a leave waits at most 15 seconds for the lock, longer than the herdr call a holder may
make, and then fails, so a stopped holder cannot block it for good. `App#me` does not wait at all;
when another command holds the lock, it leaves the record to a later command, so `wait`, `spawn`
and every other command keep their deadlines.

An agent session that joined nothing is refused, so it cannot speak as the person at the
keyboard. A plain terminal acts as an address named after `USER`, created on first use or by the
first message sent to it.

## Delivery

`Postman` composes the message, checks the recipient, and delivers it before ringing anything, so
the message is safe whatever happens to the bell.

`Bell` announces it to the session holding the address. The bell text names the sender, the kind
and the id, never the body. It tries two ways, in order.

1. the harness's own channel, the Claude Code peer socket (one JSON line per connection) or
   `codex queue --thread ID`;
2. when that fails or does not exist, typing into the herdr pane, if herdr reports the agent idle,
   done or working and no dialog shows on the bottom of its screen.

Cursor has no channel of its own, so it is always rung by typing.

The result (rung, deferred, failed or absent, with the reason) is written as a receipt against
each message, and `keryx status` reads the receipts to list what did not ring.

## Between machines

A machine's name is the host part of its addresses. `App#host` takes it from `KERYX_HOST`, then
from `host` in `$XDG_CONFIG_HOME/keryx/config`, then from the machine's own name, and keeps it for
the life of the process. That file is the only one keryx reads outside the store, and only `Config`
reads it, when the host is needed and `KERYX_HOST` is empty. A line it cannot use is a warning,
while an invalid host or a file it cannot read is an error, since falling back to the machine's
name would name the machine wrongly. spawn passes `KERYX_HOST` to the new pane only when it is set,
never the host read from the file, because the new session reads the same file.

A message for an address on another host goes to `outbox/HOST/`, written in `tmp/` and linked into
`new/` like a delivery. `Forwarder` sends what waits in `new/` through `Remote`, which runs
`ssh HOST keryx __receive` with one message per line. On the other machine, `Receiver` refuses a
message for another host, one that claims to come from its own host, and one for an address it
lacks. It stores the rest under their ids, rings the local session and prints a receipt for each.
The sender then records the outcome and moves the message to `cur/` or `refused/`. The outcome is
written before the move and only once, so an attempt that fails after another one settled the
message cannot undo it, and a sender that finds the message gone from `new/` reads how it settled.
Without a receipt the message stays in `new/`, and another file in `receipts/` counts the attempts.

The outbox counts with the mailboxes when keryx decides what is answered, so the machine that
answers closes a request as soon as the reply is written, and the sender's machine once the reply
arrives. A read is recorded only on the machine where it happens. `Courier` forwards on a
schedule, rings again for bells that did not reach a session, and sends the deadline notices from
`keryx@HOST`.

## Starting a session

`keryx spawn` starts a harness in a herdr pane and waits for it to join. It checks every option and
the address first, then creates the address and posts the request, so the request is in the mailbox
before the session exists. `Spawner` splits the caller's pane, or uses a tab of its workspace, and
runs `herdr agent start`, which types the harness command into the new pane's shell. `Harness`
builds that command's arguments, and the first prompt goes last, after a `--`, as the harness's own
initial prompt. A harness that stops at a folder trust or hooks dialog keeps that prompt and acts on
it once the dialog is answered, so nothing is ever typed into the session itself. herdr's start
waits while the agent works, and the session starts working on that prompt at once, so it runs in
the background through `Runner#start` while spawn watches the store, and spawn stops it when it is
done. herdr names the agent when the start begins and keeps the name once the agent is idle or
blocked, but drops it if the agent is still working when the timeout spawn passed to herdr runs
out, so a session busy with its first request can lose its herdr name. keryx does not use that
name, since the occupant records the pane.

The new pane gets `KERYX_HOME`, and `KERYX_HOST` when it is set, through herdr, so the session joins
the store spawn watches. Codex passes its commands only the variables its `shell_environment_policy`
allows, so Codex also gets them, with the herdr socket and pane, as
`-c shell_environment_policy.set` values.

spawn then polls the store until the address has an occupant of the harness it started, in the herdr
socket and pane it started it in. Any other session that joins the address meanwhile is a conflict,
reported as an error and never taken for the new session. spawn never answers a dialog. herdr's
`agent_not_ready`, a `blocked` agent or a screen that matches the bell's dialog patterns count as a
dialog, which spawn reports once while it keeps waiting. It stops when the pane has no agent of that
harness left or `--timeout`, counted from the moment spawn starts, passes. A join recorded after
that moment counts as too late, however soon spawn notices it.

## The stop hook

Claude Code, Codex and Cursor run `keryx hook stop` when a session is about to end its turn.
`StopHook` tells them apart by the payload and finds the session's address from the session id in
it and the environment. When there are unread messages or read requests without a reply, it keeps
the turn going, with a block decision for Claude Code and Codex and a follow-up message for Cursor.
The hook prepares a marker in `receipts/` for each reminder before it prints the decision and keeps
it once the decision is out. Every message is reminded about once, again only when the hook was cut
off before it answered, and a marker the hook cannot write ends the turn with the error, so the hook
cannot hold a session in a loop.

## The command line

`Keryx.run` builds a `CLI::Dispatcher` over the command classes in `Commands::ALL`. The dispatcher
parses the global options, finds the command, parses its options with `OptionParser`, checks the
number of arguments and calls it. A command that passes arguments to another program, as spawn does,
gets everything after the first `--` unparsed. Every error becomes a message on standard error and
one of the exit statuses `keryx --help` lists, never a backtrace. Help lists the commands of each
section in the order of `Commands::ALL`.

Commands get their services from `App`, which builds each one on first use. `keryx --help`,
`keryx version` and completion never touch the mailboxes.

Text that came from a file or from another session (message bodies, roles, herdr states) goes
through `Text.plain` before it reaches a terminal, so it cannot carry escape sequences.
