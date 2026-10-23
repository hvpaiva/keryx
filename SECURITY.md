# Security

## Reporting a vulnerability

Report it privately through
[GitHub's private vulnerability reporting](https://github.com/hvpaiva/keryx/security/advisories/new)
rather than in a public issue. You will get an answer within a week.

## What keryx protects, and what it does not

keryx connects agent sessions that one person runs on their own machines. It trusts the operating
system user. Anything running as that user can read and write the mailboxes, act as any address
with `--as`, and post to a Claude Code session's peer socket. Between machines it trusts SSH, so
whoever can log in as you on a machine can put mail in its mailboxes. Identities are labels for
coordination, not credentials. Do not use keryx between users who do not trust each other.

Mail between machines travels only over SSH, and keryx opens no port. A machine refuses mail meant
for another host and mail that claims to come from one of its own addresses, so a forwarded message
cannot pass for a local one.

Within that boundary, keryx defends against a few things that matter when the parties are
language models.

- A peer's message is not the user's word. The skill keryx gives agents says so, and tells them
  to refuse what their own user did not authorize. An agent that joined no address cannot send as
  the person at the keyboard.
- The bell carries no text from the sender. It names the sender, the kind and the id, all
  checked against strict formats when the message is read, so a message file cannot place
  arbitrary text in another session's context through a bell or a hook reminder, and neither
  carries any of the body. `keryx inbox` and `keryx status` show a summary of each message they
  list, the first line of its body that is not empty, shortened and with control characters made
  visible. The whole body comes with `keryx read` and in the JSON output of `keryx inbox` and
  `keryx status`.
- Nothing from a file or a session reaches a terminal raw. Message bodies, roles, addresses and
  herdr states are shown with control characters made visible, and `-o json` writes those
  characters as `\u` escapes, so they cannot move the cursor, change colors or reorder text with
  bidirectional controls. Roles are limited to plain words when they are set.
- Typing is the last resort. keryx types into a pane only when herdr reports the agent idle, done
  or working and the bottom of the screen shows no dialog keryx knows, so a bell does not answer
  an approval prompt, and only when herdr's session id or the pane's foreground process shows that
  the pane still runs the session that joined. keryx checks the pane's session and the agent's
  state again right before it types, after reading the screen, so a session that took the pane
  over by then gets no bell. A session that takes the pane in the moment between that check and
  the keystrokes can still receive the bell, since herdr cannot type only into a given session.
- `keryx spawn` types nothing into an agent. herdr types the harness command, each argument quoted,
  into the shell of the pane spawn just created, and the first prompt travels as an argument of
  that command. That puts the first prompt, `--prompt` included, in the harness's command line,
  which any local process can read through `/proc/PID/cmdline`, `ps` or `herdr pane process-info`,
  and the pane's shell may keep the typed command in its history, so neither the first prompt nor
  `--prompt` may carry a secret. The request, given as TEXT or with `--file`, goes to the mailbox
  instead, in files of mode 0600. spawn refuses harness arguments that hold control characters,
  makes those in `--prompt` visible, and quotes a dialog in the new pane to you and, in a message
  from keryx, to the address it runs as, but still answers none.
- Mailbox directories are created with mode 0700 and files with 0600.

`crossSessionInbound: "accept"` in a Claude Code session's settings lets any process of your user
post into that session. keryx needs it for its bells; enable it only on the sessions that take
part.
