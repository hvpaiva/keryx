# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Addresses that outlive sessions, claimed with `keryx join` and released with `keryx leave`, or
  with `keryx leave --as ADDRESS` once the session holding one ended without leaving, for Claude
  Code, Codex and Cursor sessions and any agent in a herdr pane.
- Team addresses, `MEMBER.TEAM@HOST`. A bare `MEMBER` names one of the sender's team and
  `MEMBER.TEAM` one on this machine; a sender with no team names a bare member only when one team
  here has it, and is told the matches otherwise. Two scopes are reserved: `NAME.local` is a person
  at a terminal and `keryx.system` is keryx's own notices.
- Session addresses, `MEMBER.TEAM@HOST/SESSION`, which reach one session of an address alone. A
  session that `keryx join --force` displaced stays reachable at its own until it leaves, and still
  opens by id and answers the requests it took before. Mail to a session address whose session left
  is refused with the stable address to write to, except the withdrawal of a request it holds, from
  this machine or another, and keryx's notices from another machine, which the holder reads. `who`
  and `status` list a displaced session at its session address beside the address, `whoami` gives
  the session address of the session that runs it, and their JSON gives `member`, `team`, `host`
  and `session_address`.
- Message format 2, for team and session addresses, the only format written or taken. A machine
  that runs an older keryx refuses format 2 for good, with the reason in the sender's error, or in
  `keryx status` for a message that waited in the outbox.
- A store from before team names stays as it was written. Its folders without a dot are never
  listed, read, moved or deleted, mail from an address from before team names, `NAME@HOST`, still
  reads in a team mailbox, and a request to or from one is over. `NAME@HOST` is refused wherever a
  name is typed, sent or received, with the reason, and an outbox file of that time still waiting
  to go moves once to `refused/` with its reason.
- Mailboxes of plain files under `$XDG_STATE_HOME/keryx`, with atomic delivery, no locks but around
  mail to a session address and the context notices, and each message stored once however often it
  arrives.
- `send`, `ask`, `inbox`, `read`, `reply` and `wait`, with request deadlines and threads. Agents
  can write to the person at the keyboard before that person has used keryx.
- `keryx withdraw`, which closes a request its sender no longer needs answered, including one sent
  before the machine was renamed.
- Bells through the Claude Code peer socket, `codex queue` for a Codex thread herdr shows open in
  its pane, or typing into a herdr pane when no dialog shows, which is how Cursor is rung.
- `keryx hook stop`, the stop hook of Claude Code, Codex and Cursor, which reminds a session of
  unread mail and unanswered requests before it ends a turn.
- Mail between machines over SSH, with an outbox that holds it while the other machine is
  unreachable, and `keryx courier`, which forwards it, rings again for bells that did not reach a
  session and tells senders about missed deadlines.
- Thread order between machines. A message of a thread for another machine takes an id after the
  last one of its thread waiting in the outbox, whatever the clock says, and the outbox sends a
  machine's messages in id order. When the other machine cannot store one, the later messages of
  its thread in the same delivery wait with it and arrive after it, so a reply does not overtake an
  earlier message of its thread.
- `~/.config/keryx/config`, whose `host` line names the machine unless `KERYX_HOST` is set.
  `keryx spawn` passes its directory to the sessions it starts.
- `who`, `whoami` and `status`, and `ring` to retry bells that did not reach a session.
- `keryx retire`, which retires an address that no live session holds and no open request waits
  on. It leaves `who` and `status`, new mail to it is refused from this machine and from others,
  though the withdrawal of a request that reached it as it was retired still settles that request,
  and its files stay until `keryx join --revive` takes it back.
- A short view in `who` and `status`, which leave out the addresses nobody holds and nobody writes
  to and say how many they left out, with `--all` to list every address.
- The context each session uses in `who` and `status`, and the sender's on each message it sends,
  shown by `read`, all read from the usage its harness records: the Claude Code transcript, the
  Codex rollout or the footer of a Cursor pane in herdr.
- A context ceiling per session, given to `join` or `spawn` with `--ceiling`, which `who` and
  `status` show the context against, and notices from `keryx courier` to the session and its
  director when its context reaches 80% of the ceiling and when it reaches the ceiling.
- `keryx skill`, the instructions agents follow to use keryx.
- `keryx spawn`, which starts a Claude Code, Codex or Cursor session in a herdr pane labelled with
  its address, gives it that address and hands it a first request that is in its mailbox before the
  session exists.
- A 2 KiB limit on the text `keryx spawn --prompt` adds to the first prompt, and a note in spawn's
  help and SECURITY.md that the first prompt is part of the harness's command line, which any
  local process can read, so it must carry no secret.
- `keryx spawn` quotes a dialog that stops the new session and sends it as a message from keryx to
  the address spawn runs as, whose bell rings while spawn still waits.
- Shell completion for bash, zsh and fish.
- `keryx send --re ID`, which sends a message to the sender of a request in its thread and shows the
  request as taken in `status`, open until the reply, with no reminder from the stop hook.
- An ACTIVE column in `who` and `status`, and `last_activity` in their JSON, with when the harness
  last wrote the session's transcript, rollout or Cursor conversation store.
- `schema` on every `-o json` output, the version of its fields, 1 in this release, first in the
  object a command prints and in each object of the array `inbox` prints, with each command's
  fields named in its `--help`. Within a schema fields are only added; removing or renaming one, or
  changing its type or meaning, raises it.
- `join` in each address of `who -o json`, the session it lists, the holder or a displaced one:
  harness, session_id, pid, started, cwd, transcript, herdr_socket, herdr_pane and joined_at, or null
  when no session holds it, so a launcher or a page finds the session without reading the store.

[Unreleased]: https://github.com/hvpaiva/keryx/commits/main
