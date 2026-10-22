# Setting up the agents

Every agent first needs the skill that `keryx skill` prints, installed as the
[README](../README.md#install-and-set-up-the-agents) shows. The versions each harness needs are in
[compatibility and limits](compatibility.md).

All three harnesses also run `keryx hook stop` when a session is about to end its turn. If the
session has unread mail, or read a request without answering it, the hook keeps the turn going once
and says what is pending. Each message is reminded about once, so the hook never holds a session in
a loop.

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
set it only on the sessions that take part, not in your global settings. `keryx spawn`, which
starts a session in a herdr pane, passes these settings inline to each Claude Code session it
starts, so they apply to that session only.

## Codex

keryx knows a Codex session by the thread Codex runs it in and rings it with `codex queue`, which
needs the TUI on Codex's shared background server, the default. For the stop hook, add it to
`~/.codex/hooks.json`, or to a project's `.codex/hooks.json`.

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "keryx hook stop" }] }]
  }
}
```

Codex runs a new hook only after you trust it. Open `/hooks` in Codex, find the hook under Stop and
trust that one. For the same reason, `keryx spawn` installs no hook in the Codex sessions it starts.
It hands them `KERYX_HOME`, and `KERYX_HOST` when you set it, through
`-c shell_environment_policy.set`, since Codex may drop them from its commands otherwise.

## Cursor

keryx knows a Cursor session by its conversation. Cursor has no channel another process can post
to, so run it in a herdr pane, where keryx rings it by typing the bell. An idle session starts a
turn with it, and a busy one queues it as a follow-up for after the turn. Add the stop hook to
`~/.cursor/hooks.json`, or to a project's `.cursor/hooks.json`.

```json
{
  "version": 1,
  "hooks": {
    "stop": [{ "command": "keryx hook stop" }]
  }
}
```

Cursor submits the reminder as the next message of the conversation. A Cursor session outside
herdr gets no bell, and the stop hook is what tells it about new mail when its turn ends. Cursor
reads hooks only from these files, so the sessions `keryx spawn` starts have the hook only when one
of them sets it.

## Other agents

Run them in a [herdr](https://herdr.dev) pane. keryx knows them by the pane, asks herdr which agent
runs there and whether it is idle, and rings them by typing a one-line bell into the pane. It types
only when herdr reports the agent idle, done or working and nothing on the bottom of the screen
looks like a dialog the typing could answer.

herdr also gives `keryx who` and `keryx status` the state of each agent, whatever its harness.
