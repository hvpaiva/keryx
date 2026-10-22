# Compatibility and limits

## Supported environments

| Component | Support |
|---|---|
| Ruby | MRI 3.4 and 4.0. The gem requires Ruby 3.4 or later and has no runtime dependencies. |
| Operating system | Linux and macOS. |
| Claude Code | 2.1.224 or later, for its peer sockets. |
| Codex | CLI 0.149 or later, for `codex queue`, with the TUI on Codex's shared background server (the default, which `--no-daemon` turns off). |
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
  screen for the common ones, but an unknown dialog can still take the typed bell.
- `who` cannot tell whether a Codex session is alive unless it runs in a herdr pane that herdr
  recognizes.
- A Cursor session outside a herdr pane gets no bell. Its stop hook tells it about new mail when
  its turn ends, but an idle session waits until someone types to it.
