# frozen_string_literal: true

require_relative '../cli/command'

module Keryx
  module Commands
    class Purge < CLI::Command
      define 'purge', section: 'Session Commands', arguments: 'ADDRESS', min: 1, max: 1,
                      summary: 'Remove the mail of a retired address, keeping its name retired',
                      description: "Remove the mail of a retired address on this machine, for good.\n\n" \
                                   'purge takes only an address keryx retire retired here, MEMBER.TEAM or ' \
                                   'MEMBER.TEAM@HOST. It refuses ADDRESS/SESSION, an address on another machine, ' \
                                   'which is purged there, an address in a reserved scope (NAME.local is a person ' \
                                   'at a terminal, and keryx.system is keryx itself), and an address from before ' \
                                   'team names, whose folder keryx keeps as the keryx of that time wrote it. It ' \
                                   'refuses while a request waits on the address, sent to it or sent by it from ' \
                                   'here, and while a message the address sent waits in the outbox for keryx ' \
                                   "courier; the refusal names each one and what settles it.\n\n" \
                                   'purge removes from addresses/MEMBER.TEAM in the keryx state directory the ' \
                                   "address's mail, read and unread, its read marks, its receipts and the messages " \
                                   'being written. It keeps the answers to the requests the address sent, since ' \
                                   'those requests stay in other mailboxes and would show open without them. ' \
                                   'Nothing brings the rest back. Mail that other mailboxes hold stays as it is, so ' \
                                   'keryx sent and keryx history --sent still list what the address sent here, but ' \
                                   'what others sent to it goes with its mailbox, and their keryx sent no longer ' \
                                   'lists it. keryx history ADDRESS then lists only the answers purge kept, so ' \
                                   "whatever shows that history, such as a page, shows less, with no error.\n\n" \
                                   'The address stays retired. Its address.json stays, and its retired.json also ' \
                                   'says when its mail was purged and by which address, so mail to it is still ' \
                                   "refused, a plain join still refuses its name, and 'keryx join MEMBER.TEAM " \
                                   "--revive' takes it back with only the answers purge kept, saying when its mail " \
                                   "was purged.\n\n" \
                                   '--dry-run makes the same checks and says what purge would remove, and removes ' \
                                   'nothing. A purge cut short, by a crash or a kill, leaves the address purged with ' \
                                   'part of its mail, and running purge again removes the rest.',
                      examples: [['See what purging a retired reviewer would remove', 'purge rev-1.alpha --dry-run'],
                                 ['Remove its mail', 'purge rev-1.alpha'],
                                 ['List the retired addresses, with when each last had mail', 'history']]

      # What a purged mailbox holds, by the counts of Roster.purged_counts, for join --revive and history to say.
      def self.contents(answers, rest)
        parts = [("#{answers} answer(s) to requests it sent, which purge keeps" if answers.positive?),
                 ("#{rest} message(s) that a purge cut short left or that arrived after it" if rest.positive?)]
        parts.compact.join(', and ')
      end

      def define_options(parser)
        parser.on('--dry-run', 'Say what purge would remove, and remove nothing') { options[:dry_run] = true }
      end

      def call(arguments)
        name = local_name(arguments.first)
        raise Error, "no address #{app.full(name)}" unless app.store.address?(name)

        by = app.full(app.me)
        record, plan = app.store.with_occupants_lock { purge(name, by) }
        report(name, record, plan)
      end

      private

      def local_name(text)
        address = text.include?('@') ? Address.parse(text) : Address.from_name(text, host: app.host)
        if address.session
          raise Error, "#{address} is one session of #{address.stable}, and purge takes only the address itself"
        end
        unless address.local?(app.host)
          raise Error, "purge runs on the machine that holds the address; run 'keryx purge #{address.key}' on " \
                       "#{address.host}"
        end

        refuse_scope(address)
        address.key
      end

      def refuse_scope(address)
        if address.flat?
          raise Error, "#{address} names no team, as an address from before team names does, whose folder keryx " \
                       'keeps as the keryx of that time wrote it; purge takes MEMBER.TEAM or MEMBER.TEAM@HOST'
        end
        return unless address.reserved?

        raise Error, "#{address} is in a reserved scope: NAME.#{Address::LOCAL} is a person at a terminal, and " \
                     "keryx.#{Address::SYSTEM} is keryx itself, so purge takes neither"
      end

      # The checks, the mark and the removal share one hold of the occupants lock, so a join --revive lands wholly
      # before them or after.
      def purge(name, by)
        refuse_link(name)
        record = app.store.retired(name) or
          raise Error, "#{app.full(name)} is not retired; 'keryx retire #{name}' comes first"
        plan = checked_plan(name, record)
        app.store.purge(name, plan, by:, now: app.now) unless options[:dry_run]
        [record, plan]
      end

      # One read of every mailbox gives both the requests that wait on NAME and the answers purge keeps.
      def checked_plan(name, record)
        all = app.store.all_messages
        plan = app.store.purge_plan(name, Roster.answers_kept(name, all))
        refuse_purged(name, record) if record.purged? && plan.empty?
        refuse_waiting(name, *app.roster.waiting(name, app.roster.open_requests(all)))
        refuse_queued(name)
        plan
      end

      def refuse_link(name)
        return if app.store.own_folder?(name)

        raise Error, "#{File.join(Store::ADDRESSES, name)} is a symbolic link; purge removes only what a folder of " \
                     'the store holds, and changed nothing'
      end

      def refuse_purged(name, record)
        raise Error, "#{app.full(name)} was purged already, at #{record.purge_stamp}"
      end

      # A reply to the address cannot reach it once it is retired, and --as refuses to act as it, so only the sender of
      # a request to it settles one, and one it sent waits for the address to come back.
      def refuse_waiting(name, received, sent)
        count = received.size + sent.size
        return if count.zero?

        hints = received.map { answer_hint(it) } + sent.map { reply_hint(name, it) }
        raise Error, "#{app.full(name)} has #{count} open request#{'s' unless count == 1} and is purged once none " \
                     "is left: #{hints.join('; ')}"
      end

      def answer_hint(request)
        "#{request.id} from #{request.from} waits for its answer; its sender settles it with 'keryx withdraw " \
          "#{request.id}'"
      end

      def reply_hint(name, request)
        "#{request.id} it sent to #{request.to} waits for a reply, which keryx refuses to a retired address; revive " \
          "it with 'keryx join #{name} --revive' from a session, withdraw #{request.id}, and retire it again"
      end

      def refuse_queued(name)
        waiting = queued(name)
        return if waiting.empty?

        count = waiting.values.sum(&:size)
        where = waiting.map { |host, ids| "for #{host} (#{ids.join(', ')})" }.join(' and ')
        raise Error, "#{app.full(name)} has #{count} message#{'s' unless count == 1} waiting in the outbox " \
                     "#{where}; purge runs once keryx courier forwarded or refused each, as keryx status shows " \
                     'under NOT FORWARDED'
      end

      # By host, the ids of the messages from NAME that wait in the outbox, for each host that has any.
      def queued(name)
        outbox = app.store.outbox
        queued = outbox.hosts.to_h { |host| [host, outbox.queued(host).select { sent_by?(it, name) }.map(&:id)] }
        queued.reject { |_host, ids| ids.empty? }
      end

      def sent_by?(message, name) = Address.parse(message.from).key == name

      def report(name, record, plan)
        address = terminal.paint(:address, app.full(name))
        if options[:dry_run]
          terminal.puts("Purging #{address} would remove #{removed(plan)}#{kept(plan, 'keep')}. Nothing was removed.")
        elsif record.purged?
          terminal.puts("Finished purging #{address}, purged at #{record.purge_stamp}, removing #{removed(plan)}, " \
                        'which a purge cut short left or which arrived after it.')
        else
          terminal.puts("Purged #{address}, removing #{removed(plan)}#{kept(plan, 'keeping')}. Its name stays " \
                        "retired; 'keryx join #{name} --revive' takes it back without that mail.")
        end
        nil
      end

      def removed(plan)
        counts = plan.removed.transform_values(&:size)
        [counted(counts['mail'], 'message'), counted(counts['read'], 'read mark'),
         counted(counts['receipts'], 'receipt')].join(', ') +
          " and #{counted(counts['tmp'], 'file')} being written"
      end

      def kept(plan, verb)
        size = plan.kept.size
        return '' if size.zero?

        ", and #{verb} #{size == 1 ? 'an answer to a request' : "#{size} answers to requests"} it sent"
      end

      def counted(size, noun) = "#{size} #{noun}#{'s' unless size == 1}"
    end
  end
end
