# Architecture

keryx is a small command line program. Every command reads and writes the mailboxes on disk and
exits, except `keryx courier`, which a machine may keep running to forward mail and ring again.
No command depends on it being there. This page describes each piece and the rules it follows.

## The store

All state lives under one directory, `$KERYX_HOME` or `$XDG_STATE_HOME/keryx`.

```text
addresses/KEY/address.json     the address: its role and when it was created
addresses/KEY/occupant.json    the session holding it, while one does
addresses/KEY/spawned.json     the director spawn recorded for the session it started, until a session joins
addresses/KEY/retired.json     when the address was retired and by which address, until join --revive
addresses/KEY/outgoing/        sessions join --force displaced, one SESSION.json each, while they stay bound
addresses/KEY/tmp/             messages being written
addresses/KEY/mail/            every message, under its id, never moved
addresses/KEY/read/            a hard link for each message read
addresses/KEY/receipts/        bell results and hook reminders, one file per message, and context notice marks
occupants.lock                 locked while a command changes which session holds an address
outbox/HOST/new/               messages waiting to go to another machine
outbox/HOST/cur/               messages the other machine took
outbox/HOST/refused/           messages the other machine refused
outbox/HOST/receipts/          forwarding attempts and outcomes, one file each per message
outbox/HOST/outcomes.lock      locked while a command replaces an outcome that holds no decision
outbox/HOST/thread.lock        locked while a command queues a message of a thread for HOST
```

KEY is the address without its host, `MEMBER.TEAM` for a team address or the bare `NAME` of an
address from before team names, which keeps its directory. MEMBER, TEAM and NAME are each a
lowercase letter followed by up to 31 lowercase letters, digits or hyphens, so no segment holds a
dot, an underscore or a capital letter. A dotted directory therefore never collides with a flat one,
and a keryx from before team names, whose name rule refuses a dot, skips it. HOST has a rule of its
own, a lowercase letter or a digit followed by up to 62 lowercase letters, digits or hyphens, which is
one label of a DNS name, so a full domain name with dots is no host. `address.json` holds member
and team as fields, and `occupant.json` the session id keryx drew at join. Messages carry `from` and
`to` as one spelled string, `MEMBER.TEAM@HOST` or `MEMBER.TEAM@HOST/SESSION`, which `Address.parse`
reads back into the same fields. `outgoing/SESSION.json` is the occupant of a session that `join --force` displaced while it
ran; it stays until that session leaves, or until a join finds it no longer running.

A message is one JSON file named after its id. It is written whole under `tmp/`, synced, and then
linked into `mail/`. Linking is atomic, so a reader never sees half a message, and it fails when the
name already exists. Since a message never leaves `mail/`, delivering it again stores it once even
after it was read. Reading a message links it into `read/`, and the unread messages are the names in
`mail/` missing from `read/`, found without opening the files that were read.

Nothing else records state. A request is answered when some mailbox holds a reply from its
recipient, in its thread, whose `in_reply_to` is the request's id; it is withdrawn when one holds a
withdrawal from its sender to its recipient the same way; it is open until either; while open, it is
taken when one holds a plain message from its recipient to its sender the same way, which
`keryx send --re` writes; and it is read when its name is in `read/`. A taken request still waits
for its reply, so `keryx wait` keeps waiting and `keryx retire` still counts it as open.
`keryx send --re` refuses a request whose reply or withdrawal it sees in a mailbox here or in the
outbox. A withdrawal still on its way from another machine is not seen yet, so the message goes, and
the requester's machine shows nothing new, since the request is settled there. The message has
`thread` and `in_reply_to` set. Between two addresses from before team names it is of format 1, as
the section on machines says, so a machine with an older keryx stores it as a plain message and keeps
showing the request read or forwarded. `keryx withdraw` writes the withdrawal
where the request is, in the mailbox that holds it or in the outbox for its host, with the request's
own sender and recipient, since those may carry a name the machine had before. The sender is the
address of the same name on the machine that sent the request, which the store shows without a list
of former names: only this machine writes its outbox, and a message from another machine never has
its recipient's host, so a request in a mailbox whose sender and recipient share a host was sent
from here. Because no ordinary mailbox operation has to change two files together, none takes a lock
and a crash leaves nothing half done. The exceptions in mail are rewriting an outcome that holds no
decision, which takes `outcomes.lock`, as the forwarding section explains, writing a message of a
thread for another machine, which takes `thread.lock` in that machine's outbox, as the same section
explains, writing a context notice, which takes `occupants.lock`, as the section on context explains, and writing mail to a
session address, which takes it too unless it is the withdrawal of a request that mailbox holds or a
notice from keryx on another machine, as the section on delivery explains. A change of occupants
takes a lock too, as the next section explains.

Message ids are [ULIDs](https://github.com/ulid/spec), 26 characters that sort by creation time,
so a directory listing is already in order.

An address is retired while `retired.json` stands in its directory, whatever the file holds, so a
record that cannot be read never brings an address back. `Store#address_names` still lists a retired
address, because its mailbox holds the replies to the requests it sent, and `Store#all_messages`
must see them to count those requests answered. `Store#current_names` leaves it out, and the roster,
and through it who, status and the courier's rounds, walks that list, as do ring and completion.

`Store` and `Outbox` are the only code that touches these paths, and they validate every address
and host name before building a path from it.

## Identity

A command first works out which session called it (`Caller`), from what the harness exports to
the commands it runs.

- Claude Code sets `CLAUDECODE`, `CLAUDE_PID`, `CLAUDE_CODE_SESSION_ID` and
  `CLAUDE_CODE_MESSAGING_SOCKET`.
- Codex sets `CODEX_THREAD_ID`.
- Cursor sets `CURSOR_CONVERSATION_ID`.
- herdr sets `HERDR_SOCKET_PATH` and `HERDR_PANE_ID` in its panes, and answers which agent runs in
  a pane, with its session id when the harness's herdr integration reports one. A harness that sets
  none of the variables above is named by herdr and takes that session id.

A harness started from another harness's shell inherits the outer one's variables, so keryx reads
Cursor's and Codex's before Claude Code's.

`keryx join` writes these down as the address's occupant, with the harness's process and when it
started: on Linux the clock tick since boot from `/proc/PID/stat`, elsewhere `ps`'s start time in
UTC, so neither the caller's time zone nor a step of the wall clock changes it. Claude Code names
its process in `CLAUDE_PID`; for Codex and Cursor in a herdr pane, the process is the pane's
foreground group, recorded only when it is an ancestor of the join, which leaves out a Codex
session that runs its commands under Codex's shared server. Codex drops herdr's variables from the
commands it runs but keeps them itself, and hands its thread id only to those commands, so the
harness that runs a command is the first process up from it whose environment lacks the caller's
thread. On Linux keryx reads only that variable and herdr's two from `/proc/PID/environ`, and
records the pane the harness's variables name, with the harness as the process, when herdr shows
the harness as that pane's foreground group. A Codex that another Codex started without herdr's
variables, or a shared server that inherited some pane's, places nothing, since the harness found
holds no variables or is not the foreground of their pane, and elsewhere such a session records no
pane. A command that proves no pane keeps the one recorded, and a record without a start field,
written before keryx kept processes, gets one from the session's next command when it can.
Later commands find their address by matching the caller against the occupants (`Identity`),
which means the same Claude Code process or session, the same Codex thread or Cursor
conversation, or the same harness in the same herdr pane. The pane rule lets a session restarted in its pane keep its address, and `App#me` then
records the new process and socket. It keeps the recorded process until `ps` shows that the
command no longer runs under it or that another process now has its pid, so a lookup that fails
erases nothing.

Whether a session is live comes from that process, alive with its recorded start time, or else
from its pane: gone when herdr shows no agent, another harness or another session there, live
otherwise, and unknown with neither a process nor a pane. What herdr says the agent is doing
(idle, working, unknown) only describes a live session in `keryx who`. join takes an address whose
session is not live, and `leave --as` releases it.

A session holds one address, so join also releases any other address the session holds. It checks
the address, releases the others and writes the occupant under an exclusive `flock` on
`occupants.lock`, so two joins that run at once, of one session or of two, take turns. The kernel
drops the lock when a process ends, so a crash never leaves it held, but the lock does not make
those writes one transaction, and a join cut off between releasing and writing leaves the session
with no address until it joins again. `App#me` records a new process or socket under the same lock,
from the occupant it reads again there, so it never writes back an address a join released. `leave`
finds the session's address and removes it under the lock too, so a refresh cannot write it back
and the occupant of a session that took the address over in between is never removed.
`leave --as ADDRESS` releases an address for a session that ended without leaving, and
`leave --as ADDRESS/SESSION` a displaced session that did the same. Under the same
lock it refuses when the roster sees the occupant live, as join does, and removes the occupant
otherwise, so a session that joins in between keeps the address. `keryx retire ADDRESS` checks and
writes in one hold of the lock too. It refuses while the roster sees the occupant live and while an
open request waits on the address, sent to it or sent by it from here, and then removes
`occupant.json` and `spawned.json` before it writes `retired.json`. The occupant goes because a
session restarted in the old holder's herdr pane would otherwise find the address as its own by the
pane rule, and it goes first, so a retire cut short leaves an address nobody holds rather than a
retired one with an occupant. The address a plain terminal acts as cannot be retired, since every
command from that terminal would create it again, and an address on another machine is retired
there, since only that machine sees its session and its mail. `Postman` and `Receiver` refuse new
mail to a retired recipient, `Identity` refuses it to `--as`, spawn refuses it, and join takes it only with
`--revive`, which removes `retired.json` in the hold where it binds the session. Delivery to an
address takes no lock against retire, so a message whose sender checked the address just before
`retired.json` landed still lands in its mailbox. That stays visible: a request among such messages
shows open in its sender's `keryx status`, and `keryx withdraw` settles it, since a withdrawal goes
where its request is and `Receiver` takes into a retired mailbox the withdrawal of a request it
holds. The writes that take `occupants.lock` anyway, a context notice and mail to a session address
other than the withdrawal of a request it holds, as the section on the store says, take turns with retire, and
mail to a session address then finds
no session bound, since retire unbinds every session of the address before it writes
`retired.json`, so it is refused. spawn checks the address for
the last time under the lock, right before it starts the harness, and refuses there an address
retired since its first check, as retire writes `retired.json` in a hold of the same lock. When it
frees the herdr name its own pane kept from an address the session there left, it clears the name
in that same hold, so a join lands before the check, which stops spawn, or after the clear, which
then freed the name of an address no session held. A retire can still land after the check when
spawn carries no request, since then nothing holds the address while the harness starts. The
session's join is refused, and spawn stops at its next look for the join, saying the session runs
with no address, rather than wait for it until its timeout.

A join or a leave waits at most 15 seconds for the lock, longer than the herdr call a holder may
make, and then fails, so a stopped holder cannot block it for good. spawn waits as long, but not
past its own timeout. `App#me` does not wait at all;
when another command holds the lock, it leaves the record to a later command, so `wait`, `spawn`
and every other command keep their deadlines.

An agent session that joined nothing is refused, so it cannot speak as the person at the
keyboard. A plain terminal acts as a member of the local scope named after `USER`, lowercased, with
each character other than a to z, a digit or a hyphen turned into a hyphen, what comes before the
first letter dropped and the rest cut to 32 characters, or `human` when nothing is left, so
`USER=john_doe` acts as `john-doe.local`. That address is created on first use or by the first
message sent to it.

An address is `MEMBER.TEAM@HOST`. Two team names are reserved scopes with no authority of their own:
`local` is a person at a terminal, and `system` is keryx's own services, so the courier's notices and
spawn's quotes of a dialog come from `keryx.system@HOST`. join takes `MEMBER.TEAM`, and of the local
scope only the name this host's terminal acts as, so that a session can answer for that person; it
refuses every system name. `Resolver` turns what a user types into a full address before anything is
stored. `MEMBER.TEAM` is on this host. A bare `MEMBER` takes the sender's team, and a sender with no
team of its own (local, system, or an address from before team names) reaches it only when exactly
one team on this host has that member, else the error lists the matches or says there is none.
Either short form takes `/SESSION` for a session address on this host, as `MEMBER.TEAM/SESSION` or
`MEMBER/SESSION`. What holds an `@` is read whole, as `MEMBER.TEAM@HOST` with or without `/SESSION`,
and `MEMBER@HOST` is an address from before team names, never a member of the sender's team: send
and ask refuse it with the spelling to use, and since such an address has no session addresses,
`MEMBER@HOST/SESSION` is refused wherever it is typed. `--as`, ring and retire resolve the same way,
and also take an address from before team names, typed whole.

Each join draws a session id, six characters of lowercase Crockford base32, redrawn while a bound
session of the address has it, and a command that records the session's process again keeps it.
`MEMBER.TEAM@HOST/SESSION` names that incarnation alone. When `join --force` takes the address from a
session that still runs, that session's occupant moves to `outgoing/SESSION.json`, and inside a
command it acts as `KEY/SESSION` while the holder acts as `KEY`. A displaced session lists, rings,
counts and is reminded of only the mail to its session address, and opens by id the mail to the
stable address as well, which holds the work it took before; it never opens another session's mail.
The holder sees everything else, including the mail to a session that left. In a thread, any
incarnation of the address a message went to writes as that address, so a displaced session's reply
still settles a request sent to the stable address. A join drops the displaced records whose session
no longer runs, and retire refuses while a displaced session runs. retire takes only the stable
address, since retiring ends the address for every session, and refuses a session address with the
stable one to give instead.

## Delivery

`Postman` composes the message, checks the recipient, and delivers it before ringing anything, so
the message is safe whatever happens to the bell.

`Bell` announces it to the session holding the address. The bell text names the sender, the kind
and the id, never the body. It tries two ways, in order.

1. the harness's own channel, the Claude Code peer socket (one JSON line per connection) or
   `codex queue --thread ID`;
2. when that fails or does not exist, typing into the herdr pane, if herdr shows an agent of the
   session's harness there, reports it idle, done or working, and no dialog shows on the bottom of
   its screen. A dialog is told by its phrases, matched with the lines joined and box borders
   dropped since a narrow pane wraps it; by its options, a selection marker (`›`, `❯` or `▶`) on a
   number, a key such as `[a]`, or a Yes or No, with another option at the same column below it; or
   by its footer, such as "enter confirm · esc skip", matched with no spaces at all since a pane
   narrower than a word breaks the words. The phrases are never matched without spaces, so code such
   as `allowOnce` does not count. A screen of at least four lines with no more than three
   characters on any of them, as a pane of a few columns shows, cannot show either, so the bell
   defers there too, saying the pane is too narrow to tell. A pane that is empty or runs another
   harness no longer holds the session, so the bell is absent there rather than typed into whoever
   took the pane.

   Every dialog keryx knows takes the place of the harness's composer, the prompt line under its
   transcript (`›` for Codex, `❯` for Claude Code, `→` for Cursor). So when the screen shows a
   composer, the phrases, options and footer are looked for only on the lines below the last one,
   and a transcript that quotes a dialog's words does not count; without one, every line is read.
   A prompt line that marks an option, or has a line beside it at the column of its text as the
   selected entry of a menu has, is no composer. The cost is that a dialog drawn above a live
   composer goes unseen, and none of the known ones is. The narrow pane rule reads every line.
   Cursor's follow-ups box, which lists the messages Cursor queued for the end of its turn above its
   composer, ends with "enter steer · ↑ select/edit · esc cancel", a footer like a dialog's, so it
   is never read, from its `┌─ follow-ups` title through its `└─┘` bottom border, or through the
   last line when that border is below the screen. Unless one of its messages is open for editing:
   then its footer reads "editing · enter done · esc close", the focus is in the box while the
   composer stays drawn below it, and a typed bell would land in the queued message. That footer is
   looked for first, on every line of the box and with no spaces so that a narrow box that wraps it
   still counts, and the bell defers, saying the screen shows a queued message being edited.
   Matching inside the box, not anywhere, keeps a transcript that quotes that footer from holding
   the bell back. A queued message taller than the pane can put the box's title above the screen,
   so the footer is also looked for in the framed lines, between `│` borders, that the screen
   starts with. Those lines are not dropped before the dialog rule, since a dialog's box can be cut
   the same way. When the footer itself is above the screen, nothing on it shows the edit.

   The rule does not read what the composer holds, and the follow-ups box is the only editor it
   knows. Codex's shift+← moves the last queued message back into its composer to be edited, which
   nothing here recognizes, so a bell typed into the pane then is added to that message. A bell to
   Codex is typed in two cases only. When herdr shows the session in its pane by its process alone,
   with no thread id, the bell is typed without trying the queue. When herdr shows the thread and
   `codex queue --thread ID` fails, the bell falls back to the pane, which is looked at and read
   again first. The queue itself types nothing into the composer.

   The detail of a deferral for a dialog or an edited message names what matched, the words keryx's own patterns took or
   a marked option, and the line of the screen it showed on, as in
   `the screen shows a dialog ("Hooks need review", line 2 of 11)`. The receipt reaches the sender,
   on whatever machine, so it never holds the rest of that line, and its control characters are
   made visible.

Cursor has no channel of its own, so it is always rung by typing.

Before typing into a pane, `Lookout` checks that the pane still runs the session that joined, and
not a session that took the pane over. herdr's integrations report the session id of the agent in
a pane; when herdr reports one, it must equal the occupant's, and an occupant that recorded none is
not taken for it. When herdr reports none, which is how a Codex session whose hooks are not trusted
looks, the pane's foreground process group must be the process the occupant records, with the
start time it records. Anything else is absent. When herdr or `ps` does not answer, the bell is
deferred. Reading the screen can take seconds, so `Bell` asks `Lookout` again once the screen shows
no dialog, right before typing, and types only if the pane still runs the session and herdr still
reports the agent idle, done or working. herdr types into a pane, not into a given session, so a
session that takes the pane in the moment between that last check and the keystrokes can still
receive the bell.

A Codex thread is queued only while herdr shows its id in the session's pane. `codex queue` hands
the message to whichever Codex app-server has the thread loaded, and Codex's shared server keeps a
thread loaded for 30 minutes after its TUI quits, then runs what was queued with no pane and no one
watching. A Codex session that the pane shows only by its process is typed into instead, and one
herdr does not show at all, or with no pane, gets no bell; the message waits in the mailbox.

The result (rung, deferred, failed or absent, with the reason) is written as a receipt against
each message, and `keryx status` reads the receipts to list what did not ring.

Mail to a session address is delivered only while that session is bound to the address and runs
(`Postman.session_left`), here and in `Receiver` for mail from another machine; once it left, the
sender is told to write to the stable address, and `keryx ring` refuses that session address in the
same words. leave and join end or move a binding in a hold of
`occupants.lock`, so the check is made again in such a hold and the message is written in the same
one (`Postman.bound`): a session that leaves after a sender first checked it gets no new mail, and
the mail written before it left stays for the holder. A receiver that finds the lock kept answers
that it failed, so the sender keeps the message and sends it again. The withdrawal of a request is
the exception, as with a retired address, so that its sender stops waiting. `Postman.withdraw` writes
it into the mailbox that holds its request, and `Receiver` writes one from another machine there when
that mailbox holds the request, both with neither the check nor the lock, whether or not the session
is still there and whether or not the address was retired since. Once the session left, the holder
of the address reads it, as it reads all mail to a session that left, and the bell finds no session
to ring. A notice from keryx on another machine, such as the ceiling notice to a director there, is
written the same way, since the courier that sends it cannot tell whether the session it goes to
still runs. `Receiver` takes the sender's address from the message, as keryx trusts SSH between
machines, so a message that names `keryx.system` gets in this way, but it could reach the holder at
the stable address all the same. An address from before team names finishes its threads and starts
no new work, so it sends and receives only replies, withdrawals and messages in an open thread.
`FlatRule` holds the rule, for what `Postman` writes here and for what `Receiver` takes from another
machine: in a thread, a message to or from such an address goes only when it answers, takes or
withdraws a request still open, so a request, a message in a thread the address never had, a reply
to a reply and a new message in a thread that is over are refused, here as on the other machine.
The refusal names the recipient when it has no team, else the sender, and says the request is over
when that is why. The receiver answers duplicate for a message the mailbox already holds, whatever
became of its thread, so a sender that lost the receipt and sends it again stops. Every message
between an address here and one elsewhere is kept in the mailbox here or in the outbox to that
machine, and one between two addresses here in their mailboxes, so `FlatRule` looks for the request
and for what answered or withdrew it there alone. keryx's own notices still reach such an address
while a live session here holds it, so that session does not go blind before it moves to a team
address, and the courier skips one that nobody holds.

## Between machines

A machine's name is the host part of its addresses. `App#host` takes it from `KERYX_HOST`, then from
`host` in `$XDG_CONFIG_HOME/keryx/config`, or `$HOME/.config/keryx/config` when that variable is
unset, empty or not absolute, then from the machine's own name, and keeps it for the life of the
process. That file is the only configuration keryx reads outside the store, and only `Config` reads
it, when the host is needed and `KERYX_HOST` is empty. A line it cannot use is a warning, while an
invalid host or a file it cannot read is an error, since falling back to the machine's name would
name the machine wrongly. Processes agree on the name only when they find the same file. spawn
passes the new pane the config directory it read, and `KERYX_HOST` only when it is set, never the
host read from the file. The courier's service and the non-interactive SSH session that receives
mail have only their own environment, so a custom `XDG_CONFIG_HOME` has to be set for them too.

A message for an address on another host goes to `outbox/HOST/`, written in `tmp/` and linked into
`new/` like a delivery. `Forwarder` moves a message in `new/` that already has an outcome by it, and
sends the rest through `Remote`, which runs `ssh HOST keryx __receive` with one message per line. On
the other machine, `Receiver` refuses a message for another host, one that claims to come from its
own host, one for an address it lacks (but not the address its own terminal acts as, named after
`USER` in the SSH session, which it creates as it stores the message), one for a retired address,
with a detail that says it is retired, so the sender's `keryx status` shows why, and one for a session
address whose session left, with a detail that names the stable address. The withdrawal of a request
the mailbox holds is refused for neither, and a notice from keryx is not refused for a session that
left, as the section on delivery says. It stores the rest under
their ids, rings the local session and prints a receipt for each. The sender then records the outcome and moves the message to
`cur/` or `refused/` by the outcome that stayed. The outcome is written before the move and its
first decision stays, so an attempt that fails or hears otherwise after another one settled the
message cannot undo it, and a sender that finds the message gone from `new/` reads how it settled.
Only an outcome file that holds no decision is written again, under `outcomes.lock`, so a second
repair keeps the first. Without a receipt the message stays in `new/`, and another file in
`receipts/` counts the attempts.

The forwarder sends a host's queue in id order, and the receiver takes the batch in that order. A
message of a thread for another host is queued in a hold of `outbox/HOST/thread.lock`, under an id
that sorts after the last message of its thread still in `new/`, so the messages of a thread go in
the order they were written even within one millisecond or across a clock set back. Only `new/`
counts, since a message that left it arrived or was refused, and the next one goes after it
whatever its id; reading `cur/` too would read every message ever forwarded for each one written.
A message that starts a thread, such as a request or a notice, takes no lock. Once a message of a
thread fails there, on a write error or a lock another command keeps, the receiver answers failed
for each later message of that thread in the batch without writing it, so they all wait for the
next round and arrive in order, and a reply never ends a thread ahead of a message written before
it. Mail written on this machine is not ordered that way, so a reply written here in the
millisecond of an earlier message of its thread can list before it in the recipient's inbox.

The outbox counts with the mailboxes when keryx decides what is answered or withdrawn, so the machine that
answers closes a request as soon as the reply is written, and the sender's machine once the reply arrives; a
withdrawal closes it on the sender's machine at once and on the recipient's once it arrives. A message sent with
`keryx send --re` shows the request taken on the recipient's machine once it is in the outbox and on the
sender's once it arrives. A read is recorded only on the machine where it happens. `Courier` forwards on a
schedule, rings again for bells that did not reach a session, and sends the deadline and context notices from
`keryx.system@HOST`.

Messages carry format 2 since team addresses. A message whose two addresses are both from before team names is
still written in format 1, so a keryx from before team names takes the replies and withdrawals that finish old
threads, and this keryx reads both. An older keryx answers a format 2 message with "not a keryx message", and
the forwarder records that refusal as final, with the reason spelled out: that machine runs a keryx from before team
addresses and must be upgraded. A refusal on the send itself is the sender's error, and the message is discarded,
as every message refused on its send is. A message that waited in the outbox and is refused when the courier or a
later send forwards it shows in `keryx status`, and stays in `outbox/HOST/refused/` to be sent again by hand.
Nothing is downgraded or retried.

## Starting a session

`keryx spawn` starts a harness in a herdr pane and waits for it to join. It checks every option and
the address first, then creates the address and posts the request, so the request is in the mailbox
before the session exists. It rings no bell for it, because the address may still name a session
that ended and the new session opens its inbox from its first prompt. `Spawner` places the session
by `herdr pane layout`, read for the caller's tab or for each tab `--tab` names. herdr gives a new
pane the floor of half the pane it splits, so spawn splits the pane that leaves the new one the most
room along the split direction, provided the terminal in the new one gets at least 80 columns and
24 rows, and otherwise opens a new tab. herdr's layout gives outer rectangles and no terminal size, so
spawn takes off the three columns and two rows herdr 0.9.5's default borders and scrollbar use. That minimum is the classic terminal: Cursor's trust box (about 76
columns), its footer and Codex's hooks screen keep whole lines, which the bell and the context
reading need, and it holds the 20 lines the bell reads with Cursor's 4 footer lines. When herdr
gives no layout for one of those panes, spawn opens the new tab too, with a notice, and never splits
a pane it could not measure. Besides splitting, the only change spawn makes to a pane it did not create is to
clear the herdr name the pane it runs in kept from an address the session there left, as the section on
identity says. `Spawner` then labels the new
pane with the address's name, and runs
`herdr agent start`, which types the harness command into the new pane's shell. `Harness` builds
that command's arguments, and the first prompt goes last, after a `--`, as the harness's own initial
prompt. A harness that stops at a folder trust or hooks dialog keeps that prompt and acts on it once
the dialog is answered, so nothing is ever typed into the session itself. herdr's start waits while
the agent works, and the session starts working on that prompt at once, so it runs in the background
through `Runner#start` while spawn watches the store, and spawn stops it when it is done. herdr
names the agent when the start begins and keeps the name once the agent is idle or blocked, but
drops it if the agent is still working when the timeout spawn passed to herdr runs out, so a session
busy with its first request can lose its herdr name. keryx does not use that name, since the
occupant records the pane. herdr's agent names take a lowercase letter and then up to 31 lowercase
letters, digits, `-` or `_`, with no dot, so spawn gives herdr `MEMBER_TEAM`, cut to 32 characters
(`Spawner.agent_name`), and the pane keeps the dotted address as its label. The first prompt's join
line names `MEMBER.TEAM`.

The new pane gets `KERYX_HOME`, `XDG_CONFIG_HOME`, and `KERYX_HOST` when it is set, through herdr,
so the session joins the store spawn watches and reads the config file spawn read. Codex passes its
commands only the variables its `shell_environment_policy` allows, so Codex also gets them, with the
herdr socket and pane, as `-c shell_environment_policy.set` values.

spawn then polls the store until the address has an occupant of the harness it started, in the herdr
socket and pane it started it in. Any other session that joins the address meanwhile is a conflict,
reported as an error and never taken for the new session. spawn never answers a dialog. herdr's
`agent_not_ready`, a `blocked` agent or a screen the bell takes for a dialog mean that one may show,
and `Dialog` then reads the pane as a person sees it, with `herdr pane read --source visible`. It
quotes only a read the bell's rule takes for a dialog below the command herdr typed, since that
command holds the first prompt, whose words could pass for one. The quote is the dialog block, from
the last box top or rule with the dialog still below it, at most 24 lines of 160 characters, with
control characters made visible. spawn prints it once and posts the same text once, as a message
from keryx to the address spawn runs as, which rings that address while spawn keeps waiting; with no
such address it posts nothing, since the post would create one. A read that is not a dialog yet
spends nothing, and the next poll reads again. A screen the bell finds too narrow to tell, or one
where a queued message is being edited, is reported as such, once, and quoted to no one. spawn stops
when the pane has no agent of that harness left or `--timeout`, counted from the moment spawn
starts, passes. The error at the timeout reads the pane again and reports what that read shows: the
dialog the pane shows then, quoted; a screen too narrow to tell; a queued message being edited; or,
when it shows none of those, only the pane to look at. A dialog quoted before goes into the error
only when that read fails, worded as what the pane showed when spawn read it earlier, since the pane
may no longer show it. A join recorded after that moment counts as too late, however soon spawn
notices it.

## The stop hook

Claude Code, Codex and Cursor run `keryx hook stop` when a session is about to end its turn.
`StopHook` tells them apart by the payload and finds the session's address from the session id in
it and the environment. When there are unread messages or read requests without a reply, it keeps
the turn going, with a block decision for Claude Code and Codex and a follow-up message for Cursor.
An unread request whose withdrawal from its sender is in the same mailbox is left out, as is the
closing call to answer every request when nothing listed is a request. A read request the session
took with `keryx send --re` is left out too, since its work goes on, and the closing call names that
command beside `keryx reply`, so a session that took work does not close the request early to quiet
the hook.
The hook prepares a marker in `receipts/` for each reminder before it prints the decision and keeps it once
the decision is out. Every message is reminded about once while it is unread, and a request once more once it
is read and has no reply, each again only when the hook was cut off before it answered, and a marker the hook
cannot write ends the turn with the error, so the hook cannot hold a session in a loop. For Claude Code the
hook also records the session's transcript path on its occupant, as the next section explains, and leaves it
to a later turn rather than wait for the occupants lock.

## Context

keryx measures how much context a session uses at the moment a command asks, from the usage its harness records
and never from the conversation itself. `Meter` has one reader per harness. A figure it cannot read is no figure,
so measuring never fails the command that asked.

- Claude Code writes a transcript for every session. The figure is the last assistant turn that is not a
  subagent's and names the session's own id: its input tokens plus the tokens it read from the cache and wrote to
  it. Claude Code names the transcript only to its hooks, so the stop hook records the path on the occupant when it
  is the file of the session the occupant records, in a folder under the `projects` directory keryx itself reads,
  `$CLAUDE_CONFIG_DIR/projects` or `~/.claude/projects`. Without it, keryx looks there, in the folder Claude Code
  names after the session's directory, and then in whichever single folder holds a file of that session. The
  transcript does not say whether the model runs a 200K or a 1M window, so a Claude Code figure has tokens only.
- Codex writes a rollout for each thread under `$CODEX_HOME/sessions` or `~/.codex/sessions`, and keryx lists them
  once per command or courier round. The rollout must open with its thread's own id, and the figure is the last
  token count event's input tokens and the model's context window. A thread with no rollout, or with more than
  one, has no figure.
- Cursor records neither, so keryx reads the footer in the last lines of its herdr pane, the line that names the
  model, its window and its labels and then the share of the window in use, and only while the pane runs the
  session that joined. A footer without a share is no figure, and no other line stands in for it.

No link is followed anywhere from the root keryx derives down to a transcript or rollout, so a file name never
leads to another session's file. A transcript or rollout is read from its end, at most 8 MiB back, so a long one
costs only its last lines. The meter parses only the lines that can carry the figure (a Claude Code assistant line
with usage, a Codex token count event, and a rollout's first line), keeps only their numbers, and takes a count
above a billion tokens, more than any window holds, for no figure.

The meter also tells when the harness last wrote the file it keeps for the session, which who and status show as
ACTIVE. It takes the file's mtime and reads nothing in it. That is the last write and not a liveness check, since a
session on a long tool call writes nothing until the call ends. For Claude Code the file is the transcript, and for
Codex the rollout, that the context figure comes from; the meter keeps both paths for its life, one command or one
courier round, so the column costs one open and stat of a path it already found, with no second glob or listing.
For Cursor keryx departs from the footer it reads for context, which carries no time: telling when it changed would
take a record per address, written from who and status, and the footer changes only with its share or its labels.
Cursor keeps each conversation in `~/.cursor/chats/MD5(cwd)/CONVERSATION_ID/`, a layout of its own that it does not
document, where the directory is the MD5 of the directory the session runs in and the conversation id is the one
Cursor gives the session in `CURSOR_CONVERSATION_ID`. The time is the later mtime of `store.db` and `store.db-wal`
there, read under the same rule of no link on the way, and a session whose files are missing has none.

A session may have a ceiling in tokens, given to `keryx join --ceiling`, and kept on its occupant with its
director, the address that spawned it. spawn puts its `--ceiling` in the join line of the first prompt, so a session
that joins after spawn gave up still has it. The director never goes on the join line, where any session could name
any address. Before the harness starts, spawn writes `spawned.json` in the address's folder with the address it runs
as, the harness, and the herdr socket and pane it starts it in. The first join of the address reads it under the
occupants lock and removes it, and takes the director only when the joining session runs that harness in that pane,
so the session spawn started takes it however late it joins, and no later session can. spawn writes it without the
lock, which would hold spawn past its timeout; only another session's join, which spawn reports as a conflict, can
come between the write and the join. A spawn with no address to run as removes what an earlier spawn left. A command
that records the session's process again keeps the ceiling and the director, and a new join starts without them.

In each round `Courier` reads the figure of every running session that has a ceiling. Once the context reaches 80%
of the ceiling, and again once it reaches the ceiling, it tells the session and its director, or the sender of the
oldest request the session has not answered when no director was recorded, from `keryx.system@HOST`. A session that
`join --force` displaced is told at its session address, and its oldest request is the oldest of those it lists,
the ones to its session address, so neither it nor the holder takes the sender of the other's work. A director that
spawned from a displaced session is recorded as `KEY/SESSION` and told there while that session is bound and runs,
and at the stable address once it left, since the holder took its work; a director taken from the oldest request
falls back the same way when it is on this machine. One on another machine is told at the address it wrote from, since
only a session here can be checked, and that machine, which can check its own sessions, takes a notice from keryx at a
session address whatever the state of its session, as the section on delivery says: the session reads it while it is
bound and runs, and the holder there once it left, whether the notice went at once or waited in the outbox. Each
notice goes once to each recipient for a join and a ceiling, marked in the session's `receipts/`, so a session that
joins again or gets another ceiling can be told again; a recipient the post failed for is tried again alone in the
next round. A recipient here that is retired takes no mail, so its notice is marked as told rather than tried in
every round, and the round that marks it says once that it did not tell it. A session first seen at or past the
ceiling is told only that it reached it, and the comparison uses whole numbers.

The courier claims a notice's id in `receipts/` in the same hold of the occupants lock as the mailbox or outbox
write. The first courier writes an id with the current time, and every other courier or later round reads that id
back. A second post of the notice is then a duplicate the mailbox or the outbox keeps once, and rings no bell,
whether two couriers passed the mark's check together or the mark failed to be written after the post. Only the
courier that writes the mark reports the notice. In that hold, before the claim, the courier reads the occupant again
and drops the figure when the session's harness, id, join or ceiling changed while it was measured, since another
session that took the address with `join --force` would otherwise get the figure of the one before, and for a notice
near the ceiling it checks the ceiling notice's claim and drops the notice once that id is claimed. A ceiling
notice's id sorts after the id the notice near it claimed for the same join and recipient, even within the same
millisecond or after the clock steps back, so whichever hold comes first, no recipient reads the notice near the
ceiling after the ceiling's. When the claim of the notice near the ceiling is damaged, that order can no longer be
proved, and the ceiling notice goes out with a fresh id all the same, since losing it costs more than the order. When
a notice's own claim is damaged, the courier writes the fresh id over it in the same hold and posts under it, so the
next courier reads that id back and the store keeps one copy. A notice posted under the damaged id and never marked
then goes out twice, which costs less than a notice held back for good. Each damage is an error of the round and a
problem, and `keryx status` reports a damaged claim until a courier writes over it or someone removes it. The bell
and the forward happen after the hold.

A message a session sends carries its figure in an optional `context` field, measured as the message is
composed and only when the sending command runs in the session that holds the address. A build that does not
know the field ignores it, and one that cannot read a stamp delivers the message without it.

## The command line

`Keryx.run` builds a `CLI::Dispatcher` over the command classes in `Commands::ALL`. The dispatcher
parses the global options, finds the command, parses its options with `OptionParser`, checks the
number of arguments and calls it. A command that passes arguments to another program, as spawn does,
gets everything after the first `--` unparsed. Every error becomes a message on standard error and
one of the exit statuses `keryx --help` lists, never a backtrace. Help lists the commands of each
section in the order of `Commands::ALL`.

Commands get their services from `App`, which builds each one on first use. `keryx --help`,
`keryx version` and completion never touch the mailboxes.

Text that came from a file or from another session (message bodies, roles, herdr states) goes
through `Text.plain` before it reaches a terminal, so it cannot carry escape sequences.
