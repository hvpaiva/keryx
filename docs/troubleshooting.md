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
- `thread ... has no herdr pane` means keryx cannot see that Codex session, and it does not queue a
  bell for it, since Codex would run a closed thread on its own.
- `no agent runs in pane ...`, `pane ... runs ..., not ...`, `pane ... runs thread ..., not ...` (or
  conversation, or session), `pane ... runs process ..., not ...`, `process ... in pane ... is not
  the one that joined` or `nothing shows that pane ... still runs the session that joined` means
  keryx cannot show that the pane still runs the session that holds the address, so it did not type
  the bell there. When `keryx who` shows that session as none, gone or unknown, it ended without
  leaving, and `keryx leave --as NAME` releases the address so that the next session to join it
  finds the message. While `who` shows it live, leave refuses, and `keryx join NAME --force` from
  the session that should hold it takes it over.
- `the session that joined pane ... recorded no process to tell it by` means herdr shows that
  pane's agent without a session id, so keryx tells the session by the process it records, and it
  recorded none. When the note adds that a keryx command run in that session can record it, the
  record has no start field, as records written before keryx kept processes do, and a keryx
  command run in that session, such as `keryx whoami`, records the process when the session runs
  its commands in its pane; `keryx ring` then reaches it. Without that part, the session joined
  with this keryx and its commands do not run under its pane's foreground process, as through
  Codex's shared server, so no command can record it. Trusting the session's hooks in `/hooks`
  lets herdr report its session id instead.
- `herdr did not answer ...`, `herdr did not say ...` or `ps did not say ...` means keryx could not
  check the pane, so the bell waits and the courier tries again.
- `the agent is ...`, `the screen shows a dialog` or `the agent is blocked` means keryx did not
  type into a herdr pane while the agent waited on something else. Answer the dialog, then run
  `keryx ring`. The dialog note names in parentheses what keryx matched, a dialog's words or a
  marked option, and the line of the screen it showed on, counted from the top of the lines keryx
  read, as in `the screen shows a dialog ("Hooks need review", line 2 of 11)`.
- `the screen shows a queued message being edited` means a message in Cursor's follow-ups box is
  open for editing, so what keryx typed would land in it, and keryx did not type. Press enter or esc
  in the box to close it, then run `keryx ring`.
- `the screen could not be read` means herdr did not return the pane's screen, so keryx could not
  rule out a dialog and did not type. The courier tries again.
- `the pane is too narrow to tell whether it shows a dialog` means the pane is only a few columns
  wide, so neither a dialog's options nor its footer fit on the screen, and keryx did not type.
  Widen the pane, then run `keryx ring`.
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
keryx uses to identify the session. Name the machine with `host` in keryx's config file at its
default path, as [Between machines](machines.md) shows, where keryx inside Codex finds it without
any variable. Set `KERYX_HOME` for Codex in `~/.codex/config.toml`, and `XDG_CONFIG_HOME` too when
you keep the config file somewhere else.

```toml
[shell_environment_policy.set]
KERYX_HOME = "/path/to/the/store"
```

## keryx wait exits with status 3

`--timeout` passed before the reply arrived. The request stays open, and the reply still rings the
asker when it comes.
