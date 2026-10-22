# keryx

Reliable messaging between AI coding agent sessions.

[![Gem](https://img.shields.io/gem/v/keryx)](https://rubygems.org/gems/keryx)
[![CI](https://github.com/hvpaiva/keryx/actions/workflows/ci.yml/badge.svg)](https://github.com/hvpaiva/keryx/actions/workflows/ci.yml)

When several coding agents run side by side, each in its own terminal pane, they have no dependable
way to talk to each other. Claude Code sessions can message other Claude Code sessions, and Codex
sessions can queue messages for other Codex sessions, but a Claude Code session cannot ask a Codex
session for anything, and a reply sent to a session that just ended is lost.

keryx (Greek for herald) gives each session an address that outlives it and a mailbox on disk. A
message is written to the mailbox first and only then announced to the recipient, through its
harness's own channel when there is one. A session that misses the announcement still finds the
message, and a Claude Code session is reminded before it ends a turn with mail it never read.

```console
$ keryx status
ADDRESSES
ADDRESS          ROLE           SESSION   UNREAD   WAITING
hvpaiva@athena   human          none      0        0
impl@athena      implementer    unknown   0        1
orq@athena       orchestrator   idle      0        0
rev-1@athena     reviewer       working   0        1

OPEN REQUESTS
ID                           FROM         TO             AGE   DUE     STATE   SUMMARY
01M5JCXQ0G4H2M7JCEB3ZADT96   orq@athena   impl@athena    10s   in 9m   read    Write a corrected copy of retry.py as retry_fixed.py
01M5JCXPYB2BSZ7JYG1S4EBA51   orq@athena   rev-1@athena   10s   in 9m   read    Review retry.py for bugs

NOT RUNG
none
```

## How it works

A session claims a name with `keryx join rev-1`, and its address becomes `rev-1@HOST`. The
address belongs to the role, not to the process. When the session ends, its mailbox keeps
receiving, and the next session to join the name finds the messages waiting.

Messages are JSON files in a Maildir-style layout under `~/.local/state/keryx`. A message is
written whole before it appears, and reading it moves it from `new/` to `cur/`.

Once a message lands, keryx rings a bell in the recipient's session. The bell carries the message
id, never its text. Claude Code sessions are rung through their peer socket and Codex sessions
through `codex queue`, so neither touches the keyboard. Any other agent running in a
[herdr](https://herdr.dev) pane is rung by typing into the pane, and only when nothing on its
screen looks like a dialog the typing could answer.

`keryx ask` sends a request that stays open until the recipient answers it with `keryx reply`,
and the reply rings the asker. Claude Code also runs `keryx hook stop` before it ends a turn. If
the session has unread mail, or read a request without answering it, the hook keeps the turn
going once and says what is pending.

A bell fails when the session is gone or busy with a dialog. The message stays in the mailbox,
`keryx status` lists it under NOT RUNG with the reason, and `keryx ring` tries again.

## Requirements

- Ruby 3.4 or later, on Linux or macOS. keryx has no runtime dependencies.
- Claude Code 2.1.224 or later, for its peer sockets.
- Codex CLI 0.149 or later, for `codex queue`, with the TUI on Codex's shared background server
  (the default; `--no-daemon` turns it off).
- herdr, for agents other than Claude Code and Codex, and to show what each agent is doing.

## Install

```sh
gem install keryx
```

Shell completion for bash, zsh and fish completes commands, flags, addresses and message ids.

```sh
keryx completion bash > "${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions/keryx"
keryx completion zsh > ~/.zfunc/_keryx   # with fpath+=~/.zfunc before compinit
keryx completion fish > ~/.config/fish/completions/keryx.fish
```

## Set up the agents

Each agent needs the keryx skill, the instructions that tell it how to join, read, answer and
write messages. Claude Code, Codex and Cursor read the same skill file.

```sh
mkdir -p ~/.claude/skills/keryx && keryx skill > ~/.claude/skills/keryx/SKILL.md
mkdir -p ~/.codex/skills/keryx && keryx skill > ~/.codex/skills/keryx/SKILL.md
mkdir -p ~/.cursor/skills/keryx && keryx skill > ~/.cursor/skills/keryx/SKILL.md
```

### Claude Code

Start the sessions that use keryx with these settings, saved for example as `keryx.json` and
passed with `claude --settings keryx.json`, or put them in a project's `.claude/settings.json`.

```json
{
  "crossSessionInbound": "accept",
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "keryx hook stop" }] }]
  }
}
```

`crossSessionInbound` lets keryx's bells in. Without it, a session that bypasses permission
prompts holds every bell for your approval. Since it opens the session to any process you run,
set it only on the sessions that take part, not in your global settings. The Stop hook is the
reminder described above.

### Codex

Nothing to configure. keryx knows a Codex session by its thread and rings it with `codex queue`.

### Other agents

Run them in a herdr pane. keryx knows them by the pane, asks herdr which agent it is and whether
it is idle, and rings them by typing a one-line bell into the pane.

## Use

The orchestrating session and the reviewer each join an address.

```console
$ keryx join rev-1 --role reviewer
Joined rev-1@athena as a claude session (pid 4142).

$ keryx join orq --role orchestrator
Joined orq@athena as a claude session (pid 4157).
```

The orchestrator asks for a review, with a deadline.

```console
$ keryx ask rev-1 "Review PR #448: focus on the retry path" --within 30m
Asked rev-1@athena (01M5JBZ1J79RX38D7NH2M76ZDD). The bell rang through claude.
The reply will ring this session; 'keryx wait 01M5JBZ1J79RX38D7NH2M76ZDD' blocks until it arrives.
```

The reviewer's session receives the bell, opens the request and answers it.

```console
[keryx] New request for rev-1@athena from orq@athena (01M5JBZ1J79RX38D7NH2M76ZDD). Run 'keryx read 01M5JBZ1J79RX38D7NH2M76ZDD' to open it.

$ keryx read 01M5JBZ1
id        01M5JBZ1J79RX38D7NH2M76ZDD
kind      request, due in 29m
from      orq@athena
to        rev-1@athena
sent      2026-10-22 17:53:55 UTC (0s ago)

Review PR #448: focus on the retry path

Answer with: keryx reply 01M5JBZ1J79RX38D7NH2M76ZDD TEXT

$ keryx reply 01M5JBZ1 "Approved with two nits"
Replied to orq@athena (01M5JBZ1SSH67Z4YW088H3BRV0). The bell rang through claude.
```

A message id can be shortened to any unique prefix of four characters or more. You take part
from a plain terminal too. There keryx acts as an address named after `$USER`, so
`keryx send rev-1 "..."` and `keryx inbox` work without joining anything.

### Commands

| Command | What it does |
|---|---|
| `join NAME` | Claim an address for the agent session that runs it |
| `leave` | Release the address; its mailbox keeps receiving |
| `whoami` | Show the address this session acts as |
| `who` | List the addresses and the sessions holding them |
| `send ADDRESS TEXT` | Send a message that needs no reply |
| `ask ADDRESS TEXT` | Send a request that expects a reply, optionally `--within` a deadline |
| `inbox` | List unread messages, or all of them with `--all` |
| `read [ID]` | Show a message and mark it read |
| `reply ID TEXT` | Answer a message in its thread |
| `wait ID` | Block until a request you sent is answered |
| `status` | Show addresses, open requests and bells that did not ring |
| `ring [ADDRESS...]` | Ring again for unread messages |
| `hook stop` | The Claude Code Stop hook |
| `skill` | Print the agent instructions |

Every command has its own `--help`. `send`, `ask` and `reply` read long text from a file with
`--file PATH`, or from standard input with `--file -`. Listings take `-o json`.

### Environment

| Variable | Effect |
|---|---|
| `KERYX_HOME` | Where the mailboxes live, instead of `$XDG_STATE_HOME/keryx` |
| `KERYX_HOST` | The host part of addresses, instead of the machine's host name |
| `KERYX_AS` | Act as this address, like `--as` |
| `KERYX_COLOR` | `auto`, `always` or `never`, like `--color` |
| `NO_COLOR`, `FORCE_COLOR` | The usual color switches, honored in `auto` mode |
| `KERYX_DEBUG` | Print a backtrace for unexpected errors |

## Limits

- keryx delivers on one machine. Addresses carry the host name, and a message to an address on
  another host is refused.
- Identities are not authenticated. Any process running as your user can act as any address with
  `--as`. keryx coordinates sessions you run; it is not a security boundary. See
  [SECURITY.md](SECURITY.md).
- Typing into a herdr pane depends on herdr recognizing the agent's dialogs. keryx also checks the
  screen for the common ones, but an unknown dialog can still take the typed bell.
- `who` cannot tell whether a Codex session is alive unless it runs in a herdr pane that herdr
  recognizes.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the setup, the checks and the conventions, and
[ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit.

## License

[MIT](LICENSE.txt)
