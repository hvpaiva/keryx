<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/keryx-logo-on-dark.png">
    <img src="assets/brand/keryx-logo-on-light.png" alt="keryx" width="420">
  </picture>
</h1>

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
message, and a session is reminded before it ends a turn with mail it never read. Mail for a session
on another machine goes over SSH, and waits while that machine is unreachable.

```console
$ keryx status
ADDRESSES
ADDRESS            ROLE           SESSION   CONTEXT         UNREAD   WAITING
impl.dev@athena    implementer    unknown   unknown         0        1
orq.dev@athena     orchestrator   idle      303k            0        0
rev-1.dev@athena   reviewer       working   137k/258k 53%   0        1
1 address with no session and no mail is hidden; 'keryx status --all' lists it.

OPEN REQUESTS
ID                           FROM             TO                 AGE   DUE     STATE   SUMMARY
01M5JCXQ0G4H2M7JCEB3ZADT96   orq.dev@athena   impl.dev@athena    10s   in 9m   read    Write a corrected copy of retry.py as retry_fixed.py
01M5JCXPYB2BSZ7JYG1S4EBA51   orq.dev@athena   rev-1.dev@athena   10s   in 9m   read    Review retry.py for bugs

NOT RUNG
none
```

## Install and set up the agents

Requires Ruby 3.4 or later on Linux or macOS.

```sh
gem install keryx
```

To upgrade, run `gem update keryx` and restart the courier service if the machine runs one. A
session that joined under an older keryx can record what the new one needs with its next keryx
command, such as `keryx whoami`, and until it does, a Codex session whose pane shows no session id
gets no bell.

Each agent needs the keryx skill, the instructions that tell it how to join, read, answer and
write messages. Claude Code, Codex and Cursor read the same skill file.

```sh
mkdir -p ~/.claude/skills/keryx && keryx skill > ~/.claude/skills/keryx/SKILL.md
mkdir -p ~/.codex/skills/keryx && keryx skill > ~/.codex/skills/keryx/SKILL.md
mkdir -p ~/.cursor/skills/keryx && keryx skill > ~/.cursor/skills/keryx/SKILL.md
```

Claude Code, Codex and Cursor also take keryx's stop hook, which reminds a session of pending mail
before it ends a turn. Claude Code needs one more setting to let the bells in, and Cursor and any
other agent are rung in a [herdr](https://herdr.dev) pane. [Setting up the agents](docs/agents.md)
shows each one.

Install [herdr](https://herdr.dev/docs/install/) so that keryx can ring Codex, Cursor and other
agents. Run `keryx courier` on each machine as a [user service](docs/machines.md#run-the-courier),
which retries bells and mail for other machines and reports missed deadlines and context ceilings.

## Ask and answer

Each session joins an address, `MEMBER.TEAM@HOST`, which stays when the session ends. Within a team
a bare member such as `rev-1` is enough, and `MEMBER.TEAM` names one on this machine.

```console
$ keryx join orq.dev --role orchestrator
Joined orq.dev@athena as a claude session (pid 4157).
```

The orchestrator asks the reviewer for a review, with a deadline.

```console
$ keryx ask rev-1 "Review PR #448: focus on the retry path" --within 30m
Asked rev-1.dev@athena (01M5JBZ1J79RX38D7NH2M76ZDD). The bell rang through claude.
The reply will ring this session; 'keryx wait 01M5JBZ1J79RX38D7NH2M76ZDD' blocks until it arrives.
```

The reviewer's session gets a bell with the request's id, never its text. It opens the request
with `keryx read 01M5JBZ1` and answers it.

```console
$ keryx reply 01M5JBZ1 "Approved with two nits"
Replied to orq.dev@athena (01M5JBZ1SSH67Z4YW088H3BRV0). The bell rang through claude.
```

From a plain terminal you act as an address of the local scope named after `$USER`, such as
`john-doe.local` for `john_doe`, and `keryx whoami` gives its exact spelling. There
`keryx send rev-1.dev "..."` and `keryx inbox` work without joining anything.

## See what is pending

`keryx status` lists the addresses that have a session or mail, the requests still open and the
messages whose bell did not ring, with the reason, and `--all` adds the addresses nobody uses. Its CONTEXT column, which `keryx who` shows too, is how many tokens each
session's context holds, read from what its harness records. `keryx ring` rings again for unread mail, and `keryx wait ID` blocks until a
request is answered.

## More

- [Setting up the agents](docs/agents.md), with the stop hook of each harness and agents in herdr.
- [Between machines](docs/machines.md), with SSH, host names and the courier service.
- `keryx --help` for the commands, the environment and the exit statuses, and
  `keryx COMMAND --help` for each command.
- [Shell completion](docs/shell-completion.md) for bash, zsh and fish.
- [Troubleshooting](docs/troubleshooting.md) and [compatibility and limits](docs/compatibility.md).
- [How keryx works](ARCHITECTURE.md) and its [security model](SECURITY.md).
- [Contributing](CONTRIBUTING.md), [maintenance](docs/maintenance.md) and the [changelog](CHANGELOG.md).

Questions and bug reports are welcome in [GitHub issues](https://github.com/hvpaiva/keryx/issues).
Released under the [MIT license](LICENSE.txt).
