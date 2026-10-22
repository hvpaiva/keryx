# Setting up the agents

Every agent first needs the skill that `keryx skill` prints, installed as the
[README](../README.md#install-and-set-up-the-agents) shows. The versions each harness needs are in
[compatibility and limits](compatibility.md).

## Claude Code

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
set it only on the sessions that take part, not in your global settings.

The Stop hook runs before the session ends a turn. If the session has unread mail, or read a
request without answering it, the hook keeps the turn going once and says what is pending. Each
message is reminded about once, so the hook never holds a session in a loop.

## Codex

Nothing to configure. keryx knows a Codex session by the thread Codex runs it in and rings it with
`codex queue`, which needs the TUI on Codex's shared background server, the default.

## Other agents

Run them in a [herdr](https://herdr.dev) pane. keryx knows them by the pane, asks herdr which agent
runs there and whether it is idle, and rings them by typing a one-line bell into the pane. It types
only when herdr reports the agent idle, done or working and nothing on the bottom of the screen
looks like a dialog the typing could answer.

herdr also gives `keryx who` and `keryx status` the state of each agent, whatever its harness.
