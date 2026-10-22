# Between machines

An address names its machine, as in `port@zeus`. Mail for an address on another machine travels
over SSH, and nothing listens on a port. Each machine keeps its own mailboxes, and the sessions on
it only ever talk to the keryx installed there.

## Set up both machines

1. Install keryx on each machine.
2. Give each machine an SSH key that logs in to the other without a prompt. keryx runs ssh with
   `BatchMode=yes`, so a key with a passphrase needs an agent the keryx process can reach, and the
   other machine's host key must already be in `known_hosts`.
3. Make the host part of the addresses match the name each machine uses for the other in SSH. keryx
   takes its own host name from the machine, so set `KERYX_HOST` where the two differ. A laptop
   called `lap-0042` that the other machine reaches as `athena` needs `KERYX_HOST=athena`.
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
Environment=KERYX_HOST=athena
Restart=on-failure

[Install]
WantedBy=default.target
```

`ExecStart` takes the path `command -v keryx` prints. Add the same `KERYX_*` variables your shell
sets, and `SSH_AUTH_SOCK` when the key lives in an agent. Then start it.

```sh
systemctl --user daemon-reload
systemctl --user enable --now keryx-courier
journalctl --user -u keryx-courier -f
```

The journal shows one line for each message forwarded or refused, each bell rung again and each
deadline reported, and a host's waiting line only when it changes.

## What each machine sees

A request sent to another machine stays in the sender's outbox after it goes out, so both machines
list it under OPEN REQUESTS in `keryx status` until the reply arrives. Mail that has not gone out
yet is under NOT FORWARDED, with the number of attempts and the last error. A message reaches the
other machine at most once, since that machine stores it under its id and answers a second copy as
a duplicate.

When the other machine refuses a message, for example because the address does not exist there,
`keryx send` fails with its reason. A message the courier forwards later and the other machine
refuses stays under NOT FORWARDED as refused.
