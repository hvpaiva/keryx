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
outbox/HOST/new/               messages waiting to go to another machine
outbox/HOST/cur/               messages the other machine took
outbox/HOST/refused/           messages the other machine refused
outbox/HOST/receipts/          forwarding attempts and results, one file per message
```

A message is one JSON file named after its id. It is written whole under `tmp/`, synced, and then
linked into `mail/`. Linking is atomic, so a reader never sees half a message, and it fails when the
name already exists. Since a message never leaves `mail/`, delivering it again stores it once even
after it was read. Reading a message links it into `read/`, and the unread messages are the names in
`mail/` missing from `read/`, found without opening the files that were read.

Nothing else records state. A request is answered when some mailbox holds a reply whose
`in_reply_to` is the request's id; it is read when its name is in `read/`. Because no operation has
to change two files together, there are no locks and a crash leaves nothing half done.

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

A message for an address on another host goes to `outbox/HOST/`, written in `tmp/` and linked into
`new/` like a delivery. `Forwarder` sends what waits in `new/` through `Remote`, which runs
`ssh HOST keryx __receive` with one message per line. On the other machine, `Receiver` refuses a
message for another host, one that claims to come from its own host, and one for an address it
lacks. It stores the rest under their ids, rings the local session and prints a receipt for each.
The sender then moves a message to `cur/` or `refused/`. Without a receipt the message stays in
`new/`, and its file in `receipts/` counts the attempts.

The outbox counts with the mailboxes when keryx decides what is answered, so a request and its
reply look the same from both machines. `Courier` forwards on a schedule, rings again for bells that
did not reach a session, and sends the deadline notices from `keryx@HOST`.

## Starting a session

`keryx spawn` starts a harness in a herdr pane and waits for it to join. It checks every option and
the address first, then creates the address and posts the request, so the request is in the mailbox
before the session exists. `Spawner` splits the caller's pane, or uses a tab of its workspace, and
runs `herdr agent start`, which types the harness command into the new pane's shell. `Harness`
builds that command's arguments, and the first prompt goes last, after a `--`, as the harness's own
initial prompt. A harness that stops at a folder trust or hooks dialog keeps that prompt and acts on
it once the dialog is answered, so nothing is ever typed into the session itself.

The new pane gets `KERYX_HOME`, and `KERYX_HOST` when it is set, through herdr, so the session joins
the store spawn watches. Codex passes its commands only the variables its `shell_environment_policy`
allows, so Codex also gets them as `-c shell_environment_policy.set` values.

spawn then polls the store until the address has an occupant that joined after the one it found, if
any. It never answers a dialog. herdr's `agent_not_ready`, a `blocked` agent or a screen that
matches the bell's dialog patterns count as a dialog, which spawn reports once while it keeps
waiting. It stops when the pane has no agent left or `--timeout` passes.

## The stop hook

Claude Code, Codex and Cursor run `keryx hook stop` when a session is about to end its turn.
`StopHook` tells them apart by the payload and finds the session's address from the session id in
it and the environment. When there are unread messages or read requests without a reply, it keeps
the turn going, with a block decision for Claude Code and Codex and a follow-up message for Cursor.
A marker in `receipts/` records each reminder, so every message is reminded about once and the
hook cannot hold a session in a loop.

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
