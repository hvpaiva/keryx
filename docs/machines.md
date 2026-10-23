# Between machines

An address names its machine, as in `port@zeus`. Mail for an address on another machine travels
over SSH, and nothing listens on a port. Each machine keeps its own mailboxes, and the sessions on
it only ever talk to the keryx installed there.

## Set up both machines

1. Install keryx on each machine.
2. Give each machine an SSH key that logs in to the other without a prompt. keryx runs ssh with
   `BatchMode=yes`, so a key with a passphrase needs an agent the keryx process can reach, and the
   other machine's host key must already be in `known_hosts`.
3. Name each machine the way the other one reaches it in SSH, since that name is the host part of
   its addresses. keryx reads it from `host` in `~/.config/keryx/config`, or in
   `$XDG_CONFIG_HOME/keryx/config` when that is set, and takes the machine's own name when the file
   sets none. A laptop called `lap-0042` that the other machine reaches as `athena` needs this file.

   ```ini
   # ~/.config/keryx/config
   host = athena
   ```

   Every keryx process that finds the same file agrees on the name, including sessions whose harness
   drops `KERYX_*` variables and sessions in herdr panes, and `keryx spawn` passes its config
   directory to the sessions it starts. Keep the file at its default path where you can. A custom
   `XDG_CONFIG_HOME` has to reach every keryx process, including the courier's service and the
   non-interactive SSH session that receives mail, which often skips the shell setup that exports
   it. For that session, set `KERYX_REMOTE_COMMAND` on the sending machine to a command that sets
   it, such as `env XDG_CONFIG_HOME=/path/to/config keryx`. `KERYX_HOST` still wins over the file
   for the commands that see it.
4. Check that keryx starts in a non-interactive SSH session, which often skips the shell setup that
   puts tools on the `PATH`.

   ```sh
   ssh zeus keryx version
   ```

   When that fails, set `KERYX_REMOTE_COMMAND` on the sending machine to a command that works, such
   as the full path `command -v keryx` prints on the other one.

## Run the courier

`keryx send` forwards right away when the other machine answers. When it does not, because it is
asleep or off the network, the message waits in the outbox, and `keryx courier` forwards it once
the machine is back. The courier also rings again for unread mail whose bell did not reach a
session and tells the sender when a request passes its deadline without a reply, so run it on every
machine, even one that never sends across.

A systemd user service keeps it running.

```ini
# ~/.config/systemd/user/keryx-courier.service
[Unit]
Description=keryx courier

[Service]
ExecStart=/path/to/keryx courier
Restart=on-failure

[Install]
WantedBy=default.target
```

`ExecStart` takes the path `command -v keryx` prints. Add the same `KERYX_*` variables your shell
sets, `XDG_CONFIG_HOME` when you set it, and `SSH_AUTH_SOCK` when the key lives in an agent. Then
start it.

```sh
systemctl --user daemon-reload
systemctl --user enable --now keryx-courier
journalctl --user -u keryx-courier -f
```

The journal shows one line for each message forwarded or refused, each bell rung again and each
deadline reported, and a host's waiting line only when it changes. Warnings about the config file
come first, before the first round.

## The config file

Each line of the file is `key = value`. Blank lines and lines that start with `#` are skipped, and
a `#` after a value is part of the value. `host` is the only key. A line keryx cannot use, such as
an unknown key or one without `=`, is a warning that names the file and the line, and keryx goes on
without it. A host that is not a valid name, or a file that exists but cannot be read, is an error,
as an invalid `KERYX_HOST` is.

## Rename a machine

A reply closes a request only when it comes from the request's recipient, and that address carries
the host name the recipient's machine had when the request was sent. Renaming a machine while it
has open requests, sent or received, breaks the match between those requests and their replies, and
mail still waiting in an outbox is addressed to the old name. Rename a machine when `keryx status`
on both machines lists nothing under OPEN REQUESTS or NOT FORWARDED. A running courier keeps the
name it read when it started, so restart it after the rename.

```sh
systemctl --user restart keryx-courier
```

## What each machine sees

A request sent to another machine stays in the sender's outbox after it goes out, so both machines
list it under OPEN REQUESTS in `keryx status`. Each machine closes it once it holds the reply. The
machine that answers does so as soon as the reply is written, even while the reply still waits in
its outbox, and the sender's machine when the reply arrives. Mail that has not gone out yet is
under NOT FORWARDED, with the number of attempts and the last error.

Only messages cross between machines. Reading a request marks it read on the machine that holds
it, and the sender's machine keeps showing it as forwarded. A message reaches the other machine at
most once, since that machine stores it under its id and answers a second copy as a duplicate.

When the other machine refuses a message, for example because the address does not exist there,
`keryx send` fails with its reason. A message the courier forwards later and the other machine
refuses stays under NOT FORWARDED as refused.
