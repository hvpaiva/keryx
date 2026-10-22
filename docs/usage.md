# Using keryx

## Addresses

A session claims a name with `keryx join rev-1`, and its address becomes `rev-1@HOST`. The address
belongs to the role, not to the process. When the session ends, its mailbox keeps receiving, and
the next session to join the name finds the messages waiting. `keryx leave` releases the address,
and its mailbox keeps receiving.

```console
$ keryx join rev-1 --role reviewer
Joined rev-1@athena as a claude session (pid 4142).
```

An agent session that joined nothing is refused, so it cannot speak as the person at the keyboard.
A plain terminal acts as an address named after `$USER`, created on first use or by the first
message an agent sends to it.

## Messages and requests

`keryx send` delivers a message that needs no reply. `keryx ask` sends a request that stays open
until the recipient answers it with `keryx reply`, and the reply rings the asker. `--within 30m`
gives the request a deadline, which `keryx status` shows.

```console
$ keryx ask rev-1 "Review PR #448: focus on the retry path" --within 30m
Asked rev-1@athena (01M5JBZ1J79RX38D7NH2M76ZDD). The bell rang through claude.
The reply will ring this session; 'keryx wait 01M5JBZ1J79RX38D7NH2M76ZDD' blocks until it arrives.
```

The bell names the sender, the kind and the id, never the text, and the session opens the message
with `keryx read`.

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

A message id can be shortened to any unique prefix of four characters or more. `send`, `ask` and
`reply` read long text from a file with `--file PATH`, or from standard input with `--file -`.

## Bells

A message is in the mailbox before keryx rings anything, so it is safe whatever happens to the bell.
Claude Code sessions are rung through their peer socket and Codex sessions through `codex queue`,
so neither touches the keyboard. Any other agent in a herdr pane is rung by typing into the pane.

A bell fails when the session is gone or busy with a dialog. The message stays in the mailbox,
`keryx status` lists it under NOT RUNG with the reason, and `keryx ring` tries again.

## Commands

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

Every command has its own `--help`. Listings take `-o json`.

## Environment

| Variable | Effect |
|---|---|
| `KERYX_HOME` | Where the mailboxes live, instead of `$XDG_STATE_HOME/keryx` |
| `KERYX_HOST` | The host part of addresses, instead of the machine's host name |
| `KERYX_AS` | Act as this address, like `--as` |
| `KERYX_COLOR` | `auto`, `always` or `never`, like `--color` |
| `NO_COLOR`, `FORCE_COLOR` | The usual color switches, honored in `auto` mode |
| `KERYX_DEBUG` | Print a backtrace for unexpected errors |

## Exit status

| Status | Meaning |
|---|---|
| 0 | Success |
| 1 | An error, such as an unknown address or a damaged file |
| 2 | A usage error, such as an unknown command or flag, or a missing or extra argument |
| 3 | `keryx wait` gave up before the reply arrived |
| 130 | Interrupted |
