# Architecture

keryx is a small command line program. Every command reads and writes the mailboxes on disk and
exits, except `keryx courier`, which a machine may keep running to forward mail and ring again.
No command depends on it being there. This page describes each piece and the rules it follows.

## The store

All state lives under one directory, `$KERYX_HOME` or `$XDG_STATE_HOME/keryx`.

```text
addresses/KEY/address.json     the address: its role and when it was created
addresses/KEY/occupant.json    the session holding it, while one does
addresses/KEY/spawned.json     the director, harness and herdr pane spawn or expect recorded, until a session joins
addresses/KEY/retired.json     when the address was retired and by which address, and when keryx purge removed its
                               mail and by which, until join --revive
addresses/KEY/outgoing/        sessions join --force displaced, one SESSION.json each, while they stay bound
addresses/KEY/tmp/             messages being written
addresses/KEY/mail/            every message, under its id, never moved; keryx purge removes all but the answers it keeps
addresses/KEY/read/            a hard link for each message read
addresses/KEY/receipts/        bell results and hook reminders, one file per message, and context notice marks
changed                        empty; its mtime moves forward after every change to the store
occupants.lock                 locked while a command changes which session holds an address
outbox/HOST/new/               messages waiting to go to another machine
outbox/HOST/cur/               messages the other machine took
outbox/HOST/refused/           messages the other machine refused
outbox/HOST/receipts/          forwarding attempts and outcomes, one file each per message
outbox/HOST/outcomes.lock      locked while a command replaces an outcome that holds no decision
outbox/HOST/thread.lock        locked while a command queues a message of a thread for HOST
```

KEY is the address without its host, `MEMBER.TEAM`. MEMBER and TEAM are each a lowercase letter
followed by up to 31 lowercase letters, digits or hyphens, so no segment holds a dot, an underscore
or a capital letter. HOST has a rule of its
own, a lowercase letter or a digit followed by up to 62 lowercase letters, digits or hyphens, which is
one label of a DNS name, so a full domain name with dots is no host. `address.json` holds member
and team as fields, and `occupant.json` the session id keryx drew at join. Messages carry `from` and
`to` as one spelled string, `MEMBER.TEAM@HOST` or `MEMBER.TEAM@HOST/SESSION`, which `Address.parse`
reads back into the same fields. `outgoing/SESSION.json` is the occupant of a session that `join --force` displaced while it
ran; it stays until that session leaves, or until a join finds it no longer running.

A store that a keryx from before team names left keeps an address in a folder named `NAME`, with no
dot, whose `address.json` has a `name`, and mail between two such addresses in format 1. keryx takes
only `MEMBER.TEAM` as a key, so such a folder still leaves `who --all`, `status` and completion, and
it is never moved or deleted, and `keryx purge` refuses it. `keryx history NAME@HOST` is the one command that reads it, by name and
read-only, format 1 included. `Archive` reads it apart from `Store`, whose paths refuse a name with
no dot. It checks NAME against `Address::NAME`, creates, moves and deletes nothing there, and alone
passes `Message.from_json` the keyword that takes format 1. Mail from
such an address, `NAME@HOST`, in a team mailbox still lists and reads, but an answer to it is refused,
since keryx no longer writes to one, and a request with such an address at either end is over. In the
outbox, a file in `new/` of format 1 or with such an address at either end moves to `refused/` the
first time a command reads `new/`, with an outcome that gives the reason, and that command reports it
once, so it is never sent and holds back no thread. `cur/` and `refused/` skip a format 1 file quietly
and read one of format 2 like any other, and `keryx history --sent` alone reads a format 1 file there.

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
`thread` and `in_reply_to` set. `keryx withdraw` writes the withdrawal
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
takes a lock too, as the next section explains. No lock keryx takes is waited for without a
deadline. Each of these is waited for 15 seconds at most, through `Store#with_lock`, and a command
that does not get it by then fails with an error that names the file, so a holder that stopped, or
any other process that keeps the file, blocks no command for good. The courier does not fail on the
outcomes lock but leaves the message for its next round, as the forwarding section explains, and
the lock of the change signal is waited for a second, as the section on it explains.

Message ids are [ULIDs](https://github.com/ulid/spec), 26 characters that sort by creation time,
so a directory listing is already in order.

An address is retired while `retired.json` stands in its directory, whatever the file holds, so a
record that cannot be read never brings an address back. `Store#address_names` still lists a retired
address, because its mailbox holds the replies to the requests it sent, and `Store#all_messages`
must see them to count those requests answered. `keryx purge` keeps those replies for the same reason. `Store#current_names` leaves it out, and the roster,
and through it who, status and the courier's rounds, walks that list, as do ring and completion.

`Store` and `Outbox` are the only code that touches these paths, and they validate every address
and host name before building a path from it.

keryx reads nothing in the store through a symbolic link. Every file opens with `O_NOFOLLOW`, and
before it lists a folder or reads a file on its own, `Links` checks with `lstat` each entry from
below the root down, so a link anywhere from `addresses/` or `outbox/` to the file is never
followed. A linked file is skipped as not a regular file, and a linked folder is skipped with a
problem that names it; an address whose folder is a link is no address, and `join` refuses it. A
message listed in a folder is opened with `O_NOFOLLOW` alone, since the listing checked its folder,
so a listing walks its folders once and not once for each message. The root and what is above
it may be links, and so may the config file, which a dotfiles repository often keeps as one.

keryx writes nothing through a symbolic link either. Before it writes a file or makes a folder, it
refuses a link on the way with an error that names it, and the three lock files open with
`O_NOFOLLOW`, so a link in place of one is refused and its target never made. The final name never
followed a link: a file is written under a fresh name with `O_EXCL`, then renamed or hard linked
into place. Removing a file is not checked, so a linked folder on the way still leads a removal
outside the store. A bell first writes and removes a mark in its mailbox's `receipts/`, so one whose
receipt could not be written is not rung, and the courier reports that mailbox once and goes on
with the others, rather than ringing the same message on every round.

`changed` is the store's change signal, for a reader that keeps what keryx printed and runs a
command again only when the store changed. Each create, rename, hard link and removal of a file or
folder under the root moves its mtime forward: mail, read marks, receipts and bell marks, the
outbox's queues, moves and outcomes, `address.json`, `occupant.json`, `spawned.json`,
`retired.json`, `outgoing/` and what purge removes, whether a command on this machine made it or
`__receive` stored mail another machine forwarded. Temporaries and lock files do not count, and a
command that only reads moves nothing. Each write that changed the store calls `changed!` once made.
The helpers of `Links` and `Files` that make a folder, link or rename a file into place or remove
one do, and so does each create, rename or removal made outside them: `Store#mark_once` and
`#keep_mark`, `Outbox#settle`, and purge's `remove_tree` and `remove_empty` in `Retirement`. A new
write outside those helpers must call it too. The process moves the mtime once for all it noted:
when its command ends, from `Dispatcher#execute`, and before each pause, through the app's sleeper,
so `courier` between rounds, `wait`, `spawn` waiting for the join and a wait for a lock of the store
or its outbox signal their changes before they sleep. A reader that saw the mtime move and then runs a command
therefore sees every change made before it.

`Changes` sets the mtime to the later of the clock and the old mtime plus 1 ms, under a lock on the
file, so it only moves forward, apart even for two changes in one tick of the clock or after the
clock stepped back, and by enough for a reader that keeps milliseconds; a filesystem that keeps
whole seconds gets a second. The mtime is a signal and not the time of a change, and it runs ahead
of the clock until the clock catches up: by a millisecond for each change that came within a
millisecond of the one before, by the whole step after the clock stepped back, and on a filesystem
that keeps whole seconds by a second for each change in the same second as the one before. A reader
stats the file once per poll and reads nothing, compares the mtime at full resolution for
inequality, which also catches a store made again, and takes a missing file as unknown. The file is
made `0600` when missing, a link in its place is refused as for any write, and `lutime` never
follows one. The lock is waited for a second at most, since a signal holds it for microseconds. When
moving the mtime fails, the change stands, the command keeps its exit status and warns on stderr,
and its changes stay noted, so the process's next signal, or the next command that changes the
store, moves it. A courier whose signal keeps failing warns once for the life of its process, since
`App#take_problems` reports each problem once. Two cases stay unsignaled until the next change: a
process killed before its command ended, and a failure under `__receive`, whose stderr the sending
machine drops when ssh succeeds. No file shows a session that ends, which `who` sees from its pid,
the context figures and last activity read from the harnesses' transcripts, or ages and overdue
states, which come from the clock, so a reader still polls `who` and `status` for those, more
slowly.

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

A recorded process that ended does not end the session while herdr shows the recorded harness
running the recorded session id in the recorded pane, since that is a harness relaunched in its
pane, as herdr does with `--resume` when it restarts: the same session under a new process. The
check reads only and records nothing; the session's next keryx command records its new process
through `App#me`. A herdr that does not answer leaves such a session gone, as its ended process
showed. `Roster` hands the lookout its one listing of the pane's herdr, which the activity of a
live session takes anyway, so judging every session asks each herdr once at most. herdr reports
no Codex thread id, so a Codex session resumed by hand in its pane counts as gone until its next
keryx command. Nor does the check bring back keryx's Claude Code stop hook, which spawn passes in
`--settings` on the command line, or the deny of `AskUserQuestion`: herdr's relaunch does not repeat
the flags a session was launched with, so a relaunched session gets no stop hook reminders and can
ask in a dialog again.

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
`--revive`, which removes `retired.json` in the hold where it binds the session. `keryx history
ADDRESS` still lists the mail of a retired address, read and unread, and with `--sent` what it sent.
With no ADDRESS it lists the retired team addresses instead, each with when and by which address it
was retired, how many messages its mailbox holds, when the newest was written and when `keryx purge`
removed its mail, so whoever chooses what purge removes sees them side by side.
It acts as no address, so the refusal of `--as` does not apply, `Identity` never creates the person's
address for it, and it marks nothing read. It refuses a team address that is not retired, which
`inbox --all --as` lists, and reads the folder of an address from before team names, `NAME@HOST`,
retired or not, since no other command reads that folder. Delivery to an
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

`keryx purge ADDRESS` removes the mail of a retired address and keeps its name retired. It takes a
team address on this machine only, and makes its checks, writes its mark and removes the files in one
hold of the occupants lock, so a `join --revive` lands wholly before it, and purge refuses an address
that is not retired, or wholly after, and the revive says when the mail was purged. In that hold it
refuses an address folder that is a symbolic link, since removing the link would take the tombstone
with it and free the name, refuses while an open request waits on the address either way, and while
a message from the address waits in `outbox/HOST/new/`. From the same read of every mailbox it finds
the messages of the address that settle a request held outside it, here or in the outbox, which are
the answers to the requests it sent: without them those requests would read open again, so purge
keeps them, with their read marks. It then adds `purged_at` and `purged_by` to `retired.json`, before
it removes anything, and empties `tmp/`, `receipts/`, `read/` and `mail/` in that order. Each folder
and each entry in it is read with lstat: a link goes and its target stays, and `FileUtils.rm_r`
removes a link inside a folder without following it. `address.json` and `retired.json` stay, so mail
to the address is still refused as to a retired one. A purge cut short leaves the mark and part of
the mail; every reader treats the address as purged, and the next purge, which keeps the first mark,
removes the rest. A revive before that keeps what is left. Delivery takes no lock against purge, as
against retire, so a message whose sender checked the address before it was retired can still land
in the purged folder after the purge; as with retire, a request among such messages shows open for
its sender, `keryx withdraw` settles it, and a second purge removes it. A process of the same user
that swaps a folder for a link between the lstat and the removal is outside SECURITY.md's model.

A join or a leave waits at most 15 seconds for the lock, longer than the herdr call a holder may
make, and then fails, so a stopped holder cannot block it for good. The outbox's locks are waited
for as long, by the same rule. spawn waits as long, but not
past its own timeout. `App#me` does not wait at all;
when another command holds the lock, it leaves the record to a later command, so `wait`, `spawn`
and every other command keep their deadlines.

An agent session that joined nothing is refused, so it cannot speak as the person at the
keyboard. A plain terminal acts as a member of the local scope named after `USER`, lowercased, with
each character other than a to z, a digit or a hyphen turned into a hyphen, what comes before the
first letter dropped and the rest cut to 32 characters, or `human` when nothing is left, so
`USER=john_doe` acts as `john-doe.local`. That address is created on first use or by the first
message sent to it. An agent session cannot act as it, or as any address in a reserved scope, with
`--as` or `KERYX_AS` either: `Identity#existing` refuses a reserved address to an agent right after
resolving it, before it reads the store, so only a plain terminal, or a program run from one, acts as
the person and marks the person's mail read. `keryx.system` is refused to every caller, a plain
terminal included, whatever the store holds, so only keryx's own code posts as it. That holds at
keryx's own commands only, as [SECURITY.md](SECURITY.md) explains.

An address is `MEMBER.TEAM@HOST`. Two team names are reserved scopes with no authority of their own:
`local` is a person at a terminal, and `system` is keryx's own services, so the courier's notices and
spawn's quotes of a dialog come from `keryx.system@HOST`. join takes `MEMBER.TEAM`, and join and
spawn refuse every name in a reserved scope, the person's own included, since a person acts as theirs
from a terminal without joining. A session that an older keryx let join a local name holds nothing:
`Identity#held` skips a reserved name for an agent, so the session acts as no address until it joins
a team one, and that join releases the old binding. `Resolver` turns what a user types into a full
address before anything is stored. `MEMBER.TEAM` is on this host. A bare `MEMBER` takes the sender's team, and a sender with no
team of its own (local or system) reaches it only when exactly
one team on this host has that member, else the error lists the matches or says there is none.
Either short form takes `/SESSION` for a session address on this host, as `MEMBER.TEAM/SESSION` or
`MEMBER/SESSION`. What holds an `@` is read whole, as `MEMBER.TEAM@HOST` with or without `/SESSION`,
and `MEMBER@HOST`, an address from before team names, is refused wherever it is typed, with the
spelling to use. `--as`, join, ring and retire resolve the same way.

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

`Bell` announces it to the session holding the address, never with the body. The bell for one
message names its sender, its kind and its id; the one that `keryx ring` or the courier rings again
for several unread messages gives how many there are and the kind and sender of the latest, and
points to `keryx inbox`. After the sender's address the line says what the sender is, since Claude
Code shows whatever reaches its peer socket under fixed text of its own, saying another Claude
session sent it, which keryx cannot change. A person at a terminal (`NAME.local`) and keryx itself
(`keryx.system`) are told by their scope, on any machine. An agent is told by the harness of the
session that holds its address on this machine, named from keryx's own table (a Claude Code, Codex
or Cursor session), and only when that session joined in an earlier second than the message was
written. `created_at` keeps whole seconds, so a session that took the address with `join --force`
within that second cannot be told from the writer, and a bell rung again after the writer left must
not name whoever holds the address now; a session that joins and writes within one second therefore
shows its address alone. A displaced session writes as its session address, whose own record names
its harness. An agent on another machine, an address no session holds, a harness outside the table
and a record keryx cannot open or parse, whatever the reason, give the address alone, and the bell
still rings. A person who sends from a plain terminal with `--as` an agent's address gets that address's
harness named, as the message's `from` names that address. It tries two ways, in order.

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

   The detail of a deferral for a dialog or an edited message names what matched, the words keryx's
   own patterns took or a marked option, and the line of the screen it showed on, as in
   `the screen shows a dialog ("Hooks need review", line 2 of 11)`. The receipt also keeps the
   obstacle, which is dialog, editor or cramped, and the evidence, which never holds more than the
   matched words, without their quotes or their line and cut at 60 characters, and is null for a
   marked option or a cramped pane, which quote none. The receipt reaches the sender, on whatever
   machine, so it never holds the rest of that line, and its control characters are made visible.

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
each message, and `keryx status` reads the receipts to list what did not ring, with `-o json`
giving each one's obstacle, channel, time and evidence. Every result but a deferral for what the
screen shows keeps null for the obstacle and the evidence, and a receipt written before keryx kept
them, or by an older keryx on another machine, reads as null for both.

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
the stable address all the same. Nothing is written to or taken from an address from before team
names: `Postman` refuses a message to one and `Receiver` one with such an address at either end, with
the reason, which the sender's `keryx status` shows for a message that waited in the outbox. A request
with such an address at either end is over, since nothing can answer or withdraw it any more, so it is
not open: `keryx status`, the stop hook, retire's check and the courier's notices leave it out, and
`keryx wait` says so at once unless its reply came before.

## Between machines

A machine's name is the host part of its addresses. `App#host` takes it from `KERYX_HOST`, then from
`host` in `$XDG_CONFIG_HOME/keryx/config`, or `$HOME/.config/keryx/config` when that variable is
unset, empty or not absolute, then from the machine's own name, and keeps it for the life of the
process. That file is the only configuration keryx reads outside the store, and only `Config` reads
it, when the host is needed and `KERYX_HOST` is empty. A line it cannot use is a warning, while an
invalid host or a file it cannot read is an error, since falling back to the machine's name would
name the machine wrongly. Processes agree on the name only when they find the same file. spawn
passes the new pane the config directory it read, and `KERYX_HOST` only when it is set, never the
host read from the file. `keryx wiring` prints the name `App#host` resolves, so a launcher can pass it
as `KERYX_HOST` without reading the file, and fails as other commands do when there is none. The
courier's service and the non-interactive SSH session that receives mail have only their own
environment, so a custom `XDG_CONFIG_HOME` has to be set for them too.

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
`receipts/` counts the attempts. A repair that does not get the lock within 15 seconds leaves the
message in `new/` the same way, with the lock's error as its reason, so the next attempt sends it
again and the other machine keeps one copy; a message from before team names that waits on the lock
stays in `new/` with a warning until a later read moves it to `refused/`.

The forwarder sends a host's queue in id order, and the receiver takes the batch in that order. A
message of a thread for another host is queued in a hold of `outbox/HOST/thread.lock`, under an id
that sorts after the last message of its thread still in `new/`, so the messages of a thread go in
the order they were written even within one millisecond or across a clock set back. A command that
does not get that lock within 15 seconds fails with nothing queued, so the reply, `send --re`,
`send --on` or withdrawal can be sent again. Only `new/`
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

Messages carry format 2 since team addresses. Format 1, which carried only addresses from before team names, is
neither written nor taken, and a machine refuses it with that reason. An older keryx answers a format 2 message with "not a keryx message", and
the forwarder records that refusal as final, with the reason spelled out: that machine runs a keryx from before team
addresses and must be upgraded. A refusal on the send itself is the sender's error, and the message is discarded,
as every message refused on its send is. A message that waited in the outbox and is refused when the courier or a
later send forwards it shows in `keryx status`, and stays in `outbox/HOST/refused/` to be sent again by hand.
Nothing is downgraded or retried.

## The message check

The author of a set of agents has rules for what they may write to each other, and a rule that an agent must
remember is one it can forget or argue its way around. The message check puts those rules in a program root
installs. When /etc/keryx/check exists, keryx runs the checker it names on every message an agent writes, before
anything is written, and writes only what the checker accepts, so the answer comes from code and not from the
agent's compliance. `CheckConfig` reads and validates the file, `Checker` runs the process, and `Check` is the one
object `Postman` and `Receiver` ask: `Check#refusal(message, event:, command:)` gives nil when the message may be
written and the reason otherwise, which `Postman` raises as an error and `Receiver` puts in a refused receipt. A
machine with no file checks nothing, as before.

The message is composed, then checked, then written, queued or rung, and the check runs outside every store lock,
so a checker that takes its whole timeout keeps no other command waiting. `Postman#post` composes the message once,
under the id it is given or one drawn from the clock, and `Postman#screen` checks it before the local delivery or
`post_away` runs, so a refused message is never delivered, queued, forwarded or rung and creates no address. Each
command passes `command:` as it names itself, `send`, `send --re`, `send --on`, `ask`, `reply` or `spawn`.
`Postman#withdraw` checks a withdrawal as `withdraw` before it writes it to the mailbox that holds the request or
queues it for another machine. spawn posts its brief after it creates the address and before it starts the
harness, so a refused brief opens no pane; spawn prints the refusal and exits 1, and the address stays, as after a
launch that fails. The text of `--prompt` is no message and is not checked. The claim path, where a post takes its
id from a claim in a hold of the occupants lock, is open only to a sender the check exempts, since a checker there
would hold that lock for its whole timeout, and any other post that passes `claim:` raises `ArgumentError`. The
message checked is the message written, field for field, with one exception. `Postman#in_thread` queues a message
of a thread for another machine under the later of its own id and the one after the last message of its thread
still in `outbox/HOST/new/` (`Postman.renamed`), so when an earlier message of the thread waits there with a later
id, from the same millisecond or across a clock set back, the stored id follows the checked one and no other field
differs. So a checker must key no rule on the id. `Receiver#take` checks a message from another machine after
its own refusals (the host, the address, a retirement, a session that left), so no checker runs for mail refused
anyway, and before it writes it. The courier does not check again what it forwards from the outbox, and nothing
that reads, marks read, rings again, retires or purges writes a message, so none of them runs the check.

keryx reads /etc/keryx/check as `key = value` lines, split at the first `=` and stripped, and skips blank lines
and lines that start with `#`.

```text
command = /usr/local/bin/nomos-check
timeout = 10
```

`command` is required and must be an absolute path; the whole value is the path, spaces included, and never a
command line. `timeout` is a whole number of seconds from 1 to 30, 5 when the line is absent. A line with no `=`,
an unknown key, a key set twice, a line that holds a NUL byte, even at its end where stripping would drop it, and
text that is not UTF-8 refuse as well, where the user config warns and goes on. `CheckConfig#setup` opens the file
with `O_NOFOLLOW` and `O_NONBLOCK` and runs every test on the stat of the open descriptor, so the file tested is
the file read. It must be a regular file, owned by root and not writable by
group or others, and every folder above it, up to /, must be a directory, not a symbolic link, owned by root and
not writable by group or others unless it is sticky, since a folder others can write lets them rename another file
over the one in it. The checker must pass the same tests by `lstat`, since exec takes a path, must not be a link
itself, and must be executable and readable by the user keryx runs as. Its first bytes, read through a descriptor
opened with `O_NOFOLLOW`, must be `#!` or the magic of an ELF or a Mach-O binary, thin in either byte order or
universal, the same list on every system. Ruby's `Process.spawn`, like `execvp`, hands a file the kernel cannot
execute to /bin/sh as a script, so a checker without `#!` would otherwise run as shell text and its exit would
decide. A checker keryx cannot read is refused for the same reason, even one the kernel could run, such as root's
at mode 0711. Every component of both paths is then root's and closed to others, so no process of that user can
swap a file between the test and the read or the exec. The walk refuses
a path through a link, such as /bin on a merged-/usr system, athena and zeus among them, so `command` names the
checker under its real path, such as /usr/local/bin or /usr/local/lib. On Ubuntu 26.04 even /usr/bin/true is a
link, to gnutrue, and coreutils such as /usr/bin/cat link into a Rust multicall binary under
/usr/lib/cargo/bin/coreutils, so a system binary is named by the path `readlink -f` prints. A missing file is no
check, and every other problem refuses each message that needs the check, with `the check failed:` and the reason,
such as `/etc/keryx/check:3: unknown key "comand"` or `the checker /usr/local/bin/nomos-check is not owned by root`,
since the check fails closed. keryx reads the file again for each message that needs it, so a fix takes effect at
the next message with nothing to restart. Only Ruby that builds an `App` can pass another `Check`, which is how the
tests use a file of their own; no variable, flag, config line or store file moves the path.

`Checker#call` starts the checker with `Process.spawn` and the argv `[command, command]`, so the path is its whole
argv and never a command line, with / as its folder, in a process group of its own, and with an environment of exactly
four variables: `PATH=/usr/bin:/bin`, `HOME`, `LANG=C.UTF-8` and `KERYX_CHECK=1`. `HOME` is the home of the user
keryx runs as from the password database (`Checker.home`), not the `HOME` a session sets freely. Three threads
write the envelope to its standard input and close it, drain its standard output in 64 KiB chunks and drop them,
and keep the first 4096 bytes of its standard error and drop the rest, so no flood fills a pipe and stalls it. A
checker that exits without reading breaks the pipe, and its exit status decides. Once the checker is reaped,
whatever it gave, keryx sends TERM and KILL to its group, so a descendant it left behind dies with it and
`sleep 30 & exit 0` is accepted at once with nothing left running. At the timeout keryx sends the group TERM, waits
1 s (`Checker::KILL_GRACE`), sends KILL and reaps the checker, and on any way out, a result, an error or Ctrl-C,
the group is killed, the checker reaped and every pipe closed. `Runner` is not used, since it passes keryx's
environment through and reads the whole output into memory. Exit 0 accepts the message and exit 1 refuses it, with
the standard error kept, scrubbed to UTF-8, stripped of trailing whitespace and ending in `(cut at 4096 bytes)` when
it was longer, as the reason. Anything else fails, and a failure refuses the message too: another exit status, a
signal, the timeout, a checker that cannot be started, and a file or checker the tests above refuse.

The checker reads one JSON object, a newline and the end of its input. keryx writes the object on one line with no
spaces; the example is broken at commas.

```json
{"check":1,"event":"send","host":"athena","command":"send --re",
 "message":{"keryx":2,"id":"01M5WX2B7Q4N8R3T6V9Y0ZC1DE","kind":"message","from":"rev-1.keryx@athena",
  "to":"orq.keryx@athena","thread":"01M5WTTD63K9VMGZX2M3Y9CW7V","in_reply_to":"01M5WTTD63K9VMGZX2M3Y9CW7V",
  "created_at":"2026-10-26T19:40:00Z","due_at":null,"body":"Taken; the review is under way.",
  "context":{"used":103000,"window":320000}}}
```

`check` is 1, the version of the envelope. `event` is `send` in `Postman#post` and `Postman#withdraw` and `receive`
in `Receiver#take`. `host` is this machine's name, `App#host`. `command` is the command that posts, one of `send`,
`send --re`, `send --on`, `ask`, `reply`, `withdraw` and `spawn`, and null on receive. `message` is the object keryx
writes to the mailbox, of format `keryx` 2, with `id`, `kind` (message, request, reply or withdrawal), `from`, `to`,
`thread`, `in_reply_to` (null when none), `created_at` and `due_at` in UTC ISO 8601 with seconds (`due_at` null
when none), `body`, and `context` with `used` and `window` only when the sender's context was measured, absent
otherwise. A message sent with `--re` or `--on` has kind message, the request's thread, and the request's id as
`in_reply_to`. The 64 KiB limit on the body is enforced before the checker runs.

`Check#exempt?` exempts a message by the sender it names, `keryx.system` or any `NAME.local`, never by who runs the
command. An exempt message runs no checker and does not read the file, so a broken file or checker silences neither
the person at the keyboard nor the courier, and the same test runs on send and on receive. No command claims
`keryx.system`, since join refuses every reserved name and `--as` and `KERYX_AS` refuse it to every caller, a plain
terminal included, whatever the store holds, so only keryx's own code posts as it: the courier's notices, the
dialog notices and spawn's quote of a dialog. `NAME.local` is the person at a plain terminal, and an
agent session cannot act as it, though a session that clears its variables passes for that person, as the limits
below say.

On send, a refusal reaches standard error as `error: the check refused the message:` and the checker's reason on
the lines after it, with control characters made visible, or as `the check refused the message and gave no reason`,
or as `the check failed:` and why, such as `/usr/local/bin/nomos-check did not finish within 5s`. keryx exits 1,
prints nothing on standard output and writes nothing. On receive, the receipt is refused, with the detail
`the check on HOST refused the message:` and the reason's lines joined by spaces, so it fits one line of
`keryx status`, or `the check on HOST failed:` and why. A check that fails there refuses rather than fails, since a
failed receipt would have the sender send the message again on every pass and stall its thread for as long as the
checker stays broken; refused, it shows once and is sent again by hand after the fix. A sending command that
forwards at once discards the message and exits 1 with `HOST refused the message;` and the detail. A message the
courier forwards later stays in `outbox/HOST/refused/`, and `keryx status` lists it under NOT FORWARDED with state
refused and the detail, as `-o json` does under `not_forwarded`. A refused message counts for nothing, so a request
whose reply was refused stays open on both machines.

The checks on receive run inside the one `ssh HOST keryx __receive` that `Remote#deliver` bounds with
`Remote::TIMEOUT`, 60 s, of which ssh's `ConnectTimeout` takes up to 10 s. If that process outlives the bound, the
sender gets no receipts and keeps the whole batch, and the next pass sends it again, so two rules keep a host's
queue moving. First, a message the mailbox already holds (`Store#stored?`, the file whose existence makes
`Store#deliver` answer a duplicate) is answered duplicate with no check, no write and no bell, after `Receiver`'s own
refusals, so a resent batch moves past what arrived. Second, `Receiver#receive_all` notes the monotonic clock when
the batch starts, and before each check, when the time spent, the message's timeout and the 1 s kill grace would
pass `Receiver::CHECK_BUDGET`, 40 s, that message and every later one of the batch that needs a check are answered
failed, `the check on HOST ran out of time in this batch`. A failed receipt stalls its thread, so the later
messages of that thread fail behind it and the sender sends them again, in order, on the next pass, while messages
that need no check are still taken unless their thread stalled. The budget leaves 60 - 10 - 40 = 10 s for ssh's
own work, Ruby's start, reading the batch and the store's writes, and the longest timeout and its kill grace,
30 + 1 = 31 s, fit in 40 s, so every batch checks at least one message and the queue moves by at least one checked
message per pass. Bells are outside the budget, each herdr or Codex call up to `Runner`'s 10 s (`App#herdr`,
`Bell::CodexQueue`), so a batch of many deliveries can still pass `Remote::TIMEOUT`, as it could before the check.
That is a limit and not a regression: the duplicate rule keeps the queue moving on the resend, since a message
already held rings no bell again.

A message that needs the check costs the reads of the file and of the folders above it and above the checker, and
one process start, run and reap. An exempt message costs nothing, and a machine with no file one open that fails.
What that adds to a send was measured on athena on 2026-10-26, with ruby 4.0.9 on 8 cpus that other sessions kept at
a load average between 30 and 35, so the figures are an upper bound. Two hundred in-process sends each took a median
of 36 to 38 ms with no file, 57 to 67 ms with `/usr/bin/gnutrue` as the checker and 69 to 71 ms with the coreutils
`cat`, so a checker that does nothing added 21 to 33 ms at the median over two runs. A whole `keryx send` started as
a process took a median of 419 to 571 ms there. A checker written in an interpreted language adds its own start on
top of that.

The check stops what goes through keryx's own commands on a machine that has it, and no more.

- A process of the user the sessions run as can still write a message file into a mailbox directly, since the
  store belongs to that user, so a reader that must not show an unchecked message checks it again when it shows
  it.
- Another build, such as an older keryx or any Ruby that loads keryx's lib and builds an `App` with a `check:` of
  its own, or preloads a file as the tests do, runs no check or another one.
- `KERYX_HOME` does not skip the check, since /etc/keryx/check is read whatever the store; a session that moves its
  store only writes mail that no live mailbox reads.
- The person exemption is claimable by any agent session that tries. keryx tells an agent from a person only by its
  environment (`Caller.from_env`), the harness variables (`CLAUDECODE` and the Claude Code, Codex and Cursor session
  variables) and else herdr's report on the pane that `HERDR_SOCKET_PATH` and `HERDR_PANE_ID` name. Any agent
  session, in a herdr pane or not, that runs keryx with those variables cleared, with
  `env -u CLAUDECODE -u HERDR_PANE_ID` or `env -i`, is taken for the person at the terminal, sends as `NAME.local`
  and is exempt. Without the exemption a checker would see a person as the sender of such a message and accept it
  all the same, so the exemption widens little.
- On receive the sender is the one the message names. Any local process can run `keryx __receive` and feed it a
  message from `NAME.local@OTHERHOST` or `keryx.system@OTHERHOST`, and `Receiver` refuses only a sender on this
  machine, so such a message is exempt and delivered. This is keryx's trust in SSH between machines, seen from the
  local side.
- On a machine where unprivileged user namespaces are enabled, a session can build a mount namespace with a root of
  its own, in which its own file and the folders above it show as root's at /etc/keryx/check or at the checker's
  path, and keryx in that namespace honors them. zeus (Omarchy, on Arch) allows it, since `unshare -Urm true` succeeds there (`max_user_namespaces` 252700,
  `unprivileged_userns_clone` 1), and setting `unprivileged_userns_clone` to 0 would close it. athena (Ubuntu
  26.04) blocks it with `apparmor_restrict_unprivileged_userns=1`. It is the same class as running another build.
- A checker that moves a descendant to another process group escapes the group kill, and that descendant may
  outlive keryx, which still returns within the timeout.
- Once keryx sent KILL, it waits for the checker with no bound, so a checker in uninterruptible sleep (state D),
  such as one blocked on a hung network file system, holds keryx until the kernel lets it die, and on receive holds
  the batch past `Receiver::CHECK_BUDGET`. keryx also signals the group after the checker is reaped, to kill what it
  left behind, so in theory a new process group could take the same id between the reap and the signal, when
  nothing of the old group is left to keep the id in use. Killing before the reap would need `waitid` with
  `WNOWAIT`, which Ruby's core does not offer, and `Process.detach` reaps.
- A checker that starts with `#!` or a binary's magic but that the kernel still cannot load, such as a damaged
  binary, one built for another system or architecture, or a `#!` whose interpreter is itself a script without
  `#!`, fails its exec with `ENOEXEC`, and Ruby then runs /bin/sh on it, so its text runs as a shell script and its
  exit decides. keryx cannot tell that run from the parent, so root avoids it by installing a checker that runs.
- A machine without /etc/keryx/check checks nothing it receives, and a message queued before the file existed is
  checked only by the machine that receives it.
- Fail closed means that an invalid file or a broken checker refuses every agent message on that machine. The
  person's mail and keryx's notices still go, so the author can still answer and the courier still reminds.
- Two machines with different checkers can refuse on receive what the sender accepted, and the sender learns it
  from the error at once or later from `keryx status`.

## Starting a session

`keryx spawn` starts a harness in a herdr pane and waits for it to join. It checks every option and
the address first, then creates the address and posts the request, so the request is in the mailbox
before the session exists. It rings no bell for it, because the address may still name a session
that ended and the new session opens its inbox from its first prompt. `Spawner` places the session
by `herdr pane layout`, read for the caller's tab or for each tab `--tab` names. With `--workspace`,
those tabs are in the workspace with that label, which spawn finds in `herdr workspace list`, since
herdr names a workspace only by id or number, and creates with `herdr workspace create` when none has
it, labelling its one tab as it would a new tab; a session in another workspace than the caller's
gets a tab of its own unless `--tab` names one. herdr gives a new
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
prompt. Claude Code gets its name, through `-n` and `--remote-control`, the model and the effort,
`--disallowedTools AskUserQuestion`, and `--settings` with `crossSessionInbound` and the stop hook.
The deny keeps a spawned session from asking in a dialog that only a person at its pane can answer,
so it asks through keryx. It is a flag of its own rather than a `permissions.deny` in those
settings, because Claude Code takes the permissions of the last `--settings` it is given, so a
caller's own `--settings` among its arguments would drop the deny, while each `--disallowedTools`
adds to the list. It comes before `--settings` because it reads every word up to the next option as
one more tool name, and so no word of the caller's arguments can follow it. A harness that stops at a folder trust or hooks dialog keeps that prompt and acts on it once
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

After the join, the courier takes over telling the director about dialogs (`DialogNotice`). Each
round reads, with the same `herdr pane read --source visible`, the pane of every running session
whose record names a director other than the session's own address, one read per such session and
none for the others, since an orchestrator that spawned its successor under its own name has no one
else to tell. A director is a name with no host, so it is always on the session's machine, and one
recorded with a session address whose session left is told at the address that session held, as the
context notice is. A read the bell's rule takes for a dialog is quoted from the last box top or rule
with the dialog below it, as spawn's quote is, or else from below the last composer, since the
command herdr typed no longer shows and a dialog takes the composer's place; a quote that says no
action is required, as Codex's menu while it gives a request extra thought does, is a menu that
closes by itself and is told to no one. The message from keryx to the director names the session and
the pane, quotes the dialog and says to answer it at once with `herdr pane send-keys`, unless the
director's human told it not to: allow once what the session's delegation record grants, never the
option that changes a setting or stops later prompts, decline what the record does not grant or
reserves to that human, and take to that human at once only a dialog that neither the record nor
the human's standing rules cover, or one the director's harness will not let it answer.
Nothing goes to the session itself, which the dialog stops.

A dialog is told once. Its key is a SHA-256 of the quote with the selection marker taken off each
line and the time on a countdown line replaced, so a moved selection or a dialog that answers itself
after a count makes no new one. `receipts/J.dialog-shown` in the session's mailbox, where J derives
from the join and the director as the context notice's mark does, holds the key of the dialog last
told and the id its notice took, and `receipts/ID.dialog` marks the notice once it is posted. Each
round reads the record before the pane, and every change to the record is made in a hold of the
occupants lock, so a hold that finds the record other than the round read it knows that the round's
read of the pane may be older than the change; it changes nothing, and the next round reads both
again. A round whose record holds the key and its mark does nothing. Otherwise the post claims in
its hold of the occupants lock. It reads the occupant again and posts nothing for another join or
for a record that changed, so of two couriers that found the dialog untold together only the first
to claim posts it. Else it gives back the id the record holds for the same key, so a courier that
stopped between its post and its mark leaves one copy, or writes a fresh id over the record of
another dialog or one that does not parse, which is a problem and an error of the round. Only the
courier that writes the mark reports the notice. A read with no obstacle at all removes the record,
taking the lock only when the round found a record before reading the pane and removing it only when
the hold finds it as the round read it, so the same dialog shown again later, such as the same
permission question for a second command, is told again. A pane herdr does not read, a screen too
narrow to tell and a queued message being edited tell nothing and keep the record, since none of
them shows that the dialog is gone. A director retired here or with no address here takes no mail,
so the dialog counts as told and the courier that marks it says once that it did not tell it, while
a failure that passes, such as a busy lock or a full disk, is an error of each round it happens in.
Three costs remain. A round that read no record and then the dialog, and claims only after another
courier told the dialog and a third removed its record on a read with no dialog, finds no record, as
it read, and tells the dialog a second time. A screen whose dialog text keeps changing in a way the
key does not normalize is told at each change, and every notice shows in the courier's report line.
A screen with no composer and no dialog, such as Claude Code's transcript view, is read whole, so
words in it that match the bell's phrases are told as a dialog. The quote, which can hold a
command's arguments, goes into the director's mailbox, as spawn's quote does. `keryx who` shows the
director the courier tells for each session, or none, so a person watching the panes can leave to
keryx the sessions that have one.

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
come between the write and the join, and then who shows the record beside that session as the store keeps it. A
record that does not parse, lacks a field or cannot be opened is none, to join and to who, and the next join removes
it. `who -o json` gives the record as `spawned` on the address's own entry, never a session address's, so a launcher
finds the pane of a session that a dialog stops before its join, whether spawn still waits or gave up. A spawn with
no address to run as removes what an earlier spawn left.

`keryx expect` writes the same record, through the same `Store#record_spawned`, for a session that a launcher of its
own starts: the launcher opens the pane, runs expect with the harness, the pane and the socket, and then starts the
harness. expect asks herdr for the pane first, so a record never names a pane that server lacks, and then works under
the occupants lock, which spawn avoids for its timeout and expect, with no timeout to keep, can wait for, so a join
comes either before its checks or after its record. It refuses what spawn refuses, a retired address and one a live
session holds, and keeps a different record that waits unless `--replace` is given, where spawn writes over it.
Without `--replace` expect links its record into place only where none is, so a record spawn writes without the lock
between expect's read and its write is kept, and expect refuses it as it refuses any different record. The same
record again is left as it is, and so is a session that joined from that pane with that director and took the record;
both succeed, so a launcher that resumes an opening can run expect again. expect records the socket in one lexical
form, without `.`, `..` or doubled slashes and with no link followed, and a join compares the record's socket with the
session's `HERDR_SOCKET_PATH` in that form, so one socket spelled two ways is the same socket. The role and the
ceiling come from the session's own join. A command that records the session's process again keeps
the ceiling and the director, and a new join starts without them.

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
and the forward happen after the hold. The dialog notice, under "Starting a session", claims its id in the same hold the same way, and
writes over its record of the dialog last told instead of keeping the first value.

A message a session sends carries its figure in an optional `context` field, measured as the message is
composed and only when the sending command runs in the session that holds the address. A build that does not
know the field ignores it, and one that cannot read a stamp delivers the message without it.

## The command line

`Keryx.run` builds a `CLI::Dispatcher` over the command classes in `Commands::ALL`. The dispatcher
parses the global options, finds the command, parses its options with `OptionParser`, checks the
number of arguments and calls it. A command that passes arguments to another program, as spawn does,
gets everything after the first `--` unparsed. Every error becomes a message on standard error and
one of the exit statuses `keryx --help` lists. `keryx purge -o json` also prints a refusal of its own
on standard output, as an object whose outcome is refused and whose reason names it, so a reader
tells its refusals apart without reading the text. An unexpected error, a `StandardError` that is not a
`Keryx::Error`, exits 1 with its class and message, and with its backtrace only when `KERYX_DEBUG`
is set. An interrupt exits 130, Interrupted in that list, after writing only a newline to standard
error. Help lists the commands of each section in the order of `Commands::ALL`.

Commands get their services from `App`, which builds each one on first use. `keryx --help`,
`keryx version` and completion never touch the mailboxes.

Every `-o json` output carries `schema`, the version of its fields, as the first key of the object a
command prints, or of each object of the array it prints, so a reader of a list such as `inbox` still
reads an array. `CLI::Command#print_json` adds it in one place. Within a version fields are only
added; removing or renaming a field, or changing its type or meaning, raises the version, and the
first release fixes schema 1. Each command's `--help` names its fields, and a test per command pins
their keys.

Text that came from a file or from another session (message bodies, roles, herdr states) goes
through `Text.plain` before it reaches a terminal, so it cannot carry escape sequences.
