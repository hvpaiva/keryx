# Compatibility and limits

## Supported environments

| Component | Support |
|---|---|
| Ruby | MRI 3.4 and 4.0. The gem requires Ruby 3.4 or later and has no runtime dependencies. |
| Operating system | Linux and macOS. |
| Claude Code | 2.1.224 or later, for its peer sockets. |
| Codex | CLI 0.149 or later, for `codex queue`, in a herdr pane for bells. |
| Cursor | The Cursor Agent CLI, in a herdr pane for bells. |
| Other agents | Any agent that herdr recognizes in its pane. |

CI runs Ruby 3.4 and 4.0 on Linux and Ruby 4.0 on macOS. The stop hooks were last checked against
real sessions of Claude Code 2.1.308, Codex 0.163.0 and Cursor Agent 2026.10.19. `keryx spawn`,
which needs `herdr agent start`, was checked against herdr 0.9.5 with Claude Code 2.1.308, Codex
0.163.0 and Cursor Agent 2026.10.22.

## Limits

- `who` and `status` show the machine they run on. A request sent to another machine is listed on
  both, but the addresses and sessions of the other machine are not.
- Mail between machines goes through SSH with keys and OpenSSH options, and one machine forwards
  only to machines it can reach by the host part of the address.
- Identities are not authenticated. Any process running as your user can act as any address with
  `--as`. keryx coordinates sessions you run and is not a security boundary, as the
  [security policy](../SECURITY.md) explains.
- Typing into a herdr pane depends on herdr recognizing the agent's dialogs. keryx also checks the
  screen for the common ones by their phrases, options and footer, so that a dialog a narrow pane
  wraps or breaks still counts, and does not type into a pane too narrow to tell, but an unknown
  dialog can still take the typed bell. When the harness's composer shows, keryx reads only the
  lines below it, where the known dialogs take its place, so a transcript that quotes a dialog
  does not count, and a dialog drawn above a live composer would not either.
- The bell does not read what a harness's composer holds, and the only editor it knows is Cursor's
  follow-ups box, which it sees only while the box's footer is on the screen. Codex's shift+← puts
  the last queued message back into the composer to be edited, and a bell typed into the pane while
  it is there is added to that message. keryx types into a Codex pane only when herdr shows the
  session there by its process alone, with no thread id, or when `codex queue` fails for the thread
  herdr shows there. Otherwise a bell to Codex goes through `codex queue` or is not rung, and
  nothing is typed.
- `who` cannot tell whether a Codex session is alive unless it runs in a herdr pane that herdr
  recognizes. keryx finds the pane of a Codex started by hand, rather than by `keryx spawn`, only
  on Linux, where it can read the variables herdr gave the Codex process.
- A Codex session gets a bell only while herdr shows it in its pane, since Codex runs a message
  queued for a closed thread on its own. One outside a herdr pane gets no bell, and its mail waits
  in the mailbox.
- `keryx spawn` hands herdr the rest of its `--timeout`, up to five minutes, and herdr 0.9.5 drops
  the agent's name if the agent has not been idle or blocked since it started when that time runs
  out. keryx finds the session by its pane, so only herdr commands that take the agent's name
  notice.
- A Cursor session outside a herdr pane gets no bell. Its stop hook tells it about new mail when
  its turn ends, but an idle session waits until someone types to it.
