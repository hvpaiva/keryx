# Setting up the agents

Every agent first needs the skill that `keryx skill` prints, installed as the
[README](../README.md#install-and-set-up-the-agents) shows. The versions each harness needs are in
[compatibility and limits](compatibility.md).

All three harnesses also run `keryx hook stop` when a session is about to end its turn. If the
session has unread mail, or read a request without answering it, the hook keeps the turn going once
and says what is pending. Each message is reminded about once, and again only when the hook was cut
off before it answered, so the hook never holds a session in a loop.

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

keryx knows a Codex session by the thread Codex runs it in, and rings it only while herdr shows
it in the session's herdr pane. When herdr's Codex integration has reported the thread's id for the
pane, keryx queues the bell with `codex queue`. When herdr shows Codex in the pane without an id,
which is how a session looks when its hooks are not trusted, keryx types the bell into the pane,
but only while the pane's foreground process is the Codex process that joined. A Codex started by
hand in a herdr pane drops herdr's variables from its commands, and on Linux keryx finds its pane
from the Codex process itself. A Codex session outside a herdr pane, one keryx cannot place in its
pane, or one herdr no longer shows, gets no bell, and its mail waits in the mailbox. The reason is
Codex's shared server, which keeps a thread loaded for 30 minutes after its TUI quits and runs
whatever is queued for it with no pane and no one watching.

For the stop hook, add it to `~/.codex/hooks.json`, or to a project's `.codex/hooks.json`.

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "keryx hook stop" }] }]
  }
}
```

Codex runs a new hook only after you trust it. Open `/hooks` in Codex, find the hook under Stop and
trust that one. For the same reason, `keryx spawn` installs no hook in the Codex sessions it starts.
It hands them `KERYX_HOME`, `XDG_CONFIG_HOME`, `KERYX_HOST` when you set it, and their herdr pane
through `-c shell_environment_policy.set`, since Codex may drop them from its commands otherwise.

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
