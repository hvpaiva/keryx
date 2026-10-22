# Troubleshooting

## An agent cannot send

keryx refuses to send from an agent session that holds no address, with
`this claude session holds no address; run 'keryx join NAME' in it first`. The session joins an
address with `keryx join NAME`, which the skill tells agents to do first. Acting as the person at
the keyboard needs `--as` explicitly.

## Claude Code asks you to approve each bell

The session runs without `"crossSessionInbound": "accept"`, and Claude Code holds a message from
another process until you approve it. Start the session with the settings in
[Setting up the agents](agents.md#claude-code).

## A message is under NOT RUNG

The message is in the mailbox; only the bell did not reach the session. `keryx status` gives the
reason.

- `no session holds the address` means the address has no session now. The next session to join
  it finds the message.
- `the agent is ...`, `the screen shows a dialog` or `the agent is blocked` means keryx did not
  type into a herdr pane while the agent waited on something else. Answer the dialog, then run
  `keryx ring`.
- `socket ...` with an error means the Claude Code session that held the address is gone. A session
  restarted in the same herdr pane takes the address back with its first keryx command, and
  `keryx ring` then reaches it.
- `the session has no Claude Code socket, Codex thread or herdr pane` means keryx has no way to
  ring that session. Run the agent in a herdr pane.

## Mail for another machine stays under NOT FORWARDED

`keryx status` shows the last error, which is what ssh or the other machine said.

- `Connection refused`, `No route to host` or a timeout means the other machine cannot be reached
  now. The courier forwards the message once it can.
- `keryx: command not found` means a non-interactive SSH session on the other machine does not find
  keryx. Set `KERYX_REMOTE_COMMAND` to its full path, as [Between machines](machines.md) shows.
- `Host key verification failed` or `Permission denied` means ssh needs a prompt keryx cannot give.
  Log in once by hand to accept the host key, and use a key that works without a passphrase prompt.
- A message marked refused names the reason, such as an address the other machine does not have.

## Codex ends its turn with unread mail

Codex skips a hook nobody has trusted yet, and says so when it starts with "Hooks need review".
Open `/hooks`, find `keryx hook stop` under Stop and trust it. Trusting only that hook leaves your
other hooks as they were.

## Sessions inside Codex do not see the other sessions' mail

Codex passes its commands only the environment its `shell_environment_policy` allows. With
`inherit = "core"` or `"none"`, a `KERYX_HOME` or `KERYX_HOST` you exported does not reach keryx
inside Codex, so keryx reads another store or names another host. Codex still sets the thread id
keryx uses to identify the session. Set the variables for Codex in `~/.codex/config.toml`.

```toml
[shell_environment_policy.set]
KERYX_HOME = "/path/to/the/store"
```

## keryx wait exits with status 3

`--timeout` passed before the reply arrived. The request stays open, and the reply still rings the
asker when it comes.
