# Architecture

keryx is a small command line program. Every command reads and writes the mailboxes on disk and
exits; nothing keeps running between commands. This page describes each piece and the rules it
follows.

## The store

All state lives under one directory, `$KERYX_HOME` or `$XDG_STATE_HOME/keryx`.

```text
addresses/NAME/address.json    the address: its role and when it was created
addresses/NAME/occupant.json   the session holding it, while one does
addresses/NAME/tmp/            messages being written
addresses/NAME/new/            unread messages
addresses/NAME/cur/            read messages
addresses/NAME/receipts/       bell results and hook reminders, one file per message
```

A message is one JSON file named after its id. It is written whole under `tmp/`, synced, and then
linked into `new/`. Linking is atomic, so a reader never sees half a message, and it fails when the
name already exists, so delivering the same message twice stores it once. Reading a message moves
it to `cur/`.

Nothing else records state. A request is answered when some mailbox holds a reply whose
`in_reply_to` is the request's id; it is read when its file is in `cur/`. Because no operation has
to change two files together, there are no locks and a crash leaves nothing half done.

Message ids are [ULIDs](https://github.com/ulid/spec), 26 characters that sort by creation time,
so a directory listing is already in order.

`Store` is the only code that touches these paths, and it validates every address name before
building a path from it.

## Identity

A command first works out which session called it (`Caller`), from what the harness exports to
the commands it runs.

- Claude Code sets `CLAUDECODE`, `CLAUDE_PID`, `CLAUDE_CODE_SESSION_ID` and
  `CLAUDE_CODE_MESSAGING_SOCKET`.
- Codex sets `CODEX_THREAD_ID`.
- herdr sets `HERDR_SOCKET_PATH` and `HERDR_PANE_ID` in its panes, and answers which agent runs in
  a pane.

`keryx join` writes these down as the address's occupant. Later commands find their address by
matching the caller against the occupants (`Identity`), which means the same Claude Code process
or session, the same Codex thread, or the same harness in the same herdr pane. The pane rule lets a session
restarted in its pane keep its address, and `App#me` then records the new process and socket.

An agent session that joined nothing is refused, so it cannot speak as the person at the
keyboard. A plain terminal acts as an address named after `USER`, created on first use.

## Delivery

`Postman` composes the message, checks the recipient, and delivers it before ringing anything, so
the message is safe whatever happens to the bell.

`Bell` announces it to the session holding the address. The bell text names the sender, the kind
and the id, never the body. It tries two ways, in order.

1. the harness's own channel, the Claude Code peer socket (one JSON line per connection) or
   `codex queue --thread ID`;
2. when that fails or does not exist, typing into the herdr pane, if herdr reports the agent idle,
   done or working and no dialog shows on the bottom of its screen.

The result (rung, deferred, failed or absent, with the reason) is written as a receipt against
each message, and `keryx status` reads the receipts to list what did not ring.

## The stop hook

Claude Code runs `keryx hook stop` when a session is about to end its turn. `StopHook` finds the
session's address from the hook payload and the environment, and blocks the end of the turn when
there are unread messages or read requests without a reply. A marker in `receipts/` records each
reminder, so every message is reminded about once and the hook cannot hold a session in a loop.

## The command line

`Keryx.run` builds a `CLI::Dispatcher` over the command classes in `Commands::ALL`. The dispatcher
parses the global options, finds the command, parses its options with `OptionParser`, checks the
number of arguments and calls it. Every error becomes a message on standard error and an exit
status, never a backtrace.

Commands get their services from `App`, which builds each one on first use. `keryx --help`,
`keryx version` and completion never touch the mailboxes.

Text that came from a file or from another session (message bodies, roles, herdr states) goes
through `Text.plain` before it reaches a terminal, so it cannot carry escape sequences.

## Exit statuses

| Status | Meaning |
|---|---|
| 0 | Success |
| 1 | An error, such as an unknown address or a damaged file |
| 2 | A usage error: an unknown command or flag, a missing or extra argument |
| 3 | `keryx wait` gave up before the reply arrived |
| 130 | Interrupted |
