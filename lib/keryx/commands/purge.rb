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
                                   "part of its mail, and running purge again removes the rest.\n\n" \
                                   'With -o json purge prints one object: address and outcome, and for the outcomes ' \
                                   'purged, finished for a purge that finishes one cut short, and dry_run, also ' \
                                   'retired_at, retired_by, purged_at and purged_by as retired.json records them, ' \
                                   'times in ISO 8601 and null where there is none, removed, the counts of messages, ' \
                                   'read_marks, receipts and being_written it removed or would remove, and ' \
                                   "answers_kept. A refusal of purge's own, with --dry-run too, prints the outcome " \
                                   'refused with reason and error, the text it also writes to standard error, and ' \
                                   'exits 1 as without -o json. reason is session, remote with host, no_team, ' \
                                   'reserved, no_address, linked, not_retired, purged_already with purged_at and ' \
                                   'purged_by, waiting with received, each request to the address by id and from, ' \
                                   'and sent, each it sent by id and to, or queued with queued, each host and the ' \
                                   'ids that wait for it. Any other error, such as an unknown option or a damaged ' \
                                   "retired.json, prints nothing on standard output.\n\n#{SCHEMA_HELP}",
                      examples: [['See what purging a retired reviewer would remove', 'purge rev-1.alpha --dry-run'],
                                 ['Say what purging it would remove, as JSON', 'purge rev-1.alpha --dry-run -o json'],
                                 ['Remove its mail', 'purge rev-1.alpha'],
                                 ['List the retired addresses, with when each last had mail', 'history']]

      # The counts -o json gives, by the folder of the plan each counts.
      REMOVED = { 'messages' => 'mail', 'read_marks' => 'read', 'receipts' => 'receipts',
                  'being_written' => 'tmp' }.freeze

      # A refusal of purge's own, which -o json prints on stdout as the outcome refused, with its reason and the fields
      # that name what it waits on, before it goes to stderr as text, as every error does.
      class Refusal < Error
        attr_reader :address, :reason, :fields

        def initialize(message, address:, reason:, fields: {})
          super(message)
          @address = address
          @reason = reason
          @fields = fields
        end

        def record = { 'address' => address, 'outcome' => 'refused', 'reason' => reason, 'error' => message, **fields }
      end

      # What a purged mailbox holds, by the counts of Roster.purged_counts, for join --revive and history to say.
      def self.contents(answers, rest)
        parts = [("#{answers} answer(s) to requests it sent, which purge keeps" if answers.positive?),
                 ("#{rest} message(s) that a purge cut short left or that arrived after it" if rest.positive?)]
        parts.compact.join(', and ')
      end

      def define_options(parser)
        parser.on('--dry-run', 'Say what purge would remove, and remove nothing') { options[:dry_run] = true }
        output_option(parser)
      end

      def call(arguments)
        name = local_name(arguments.first)
        by = app.full(app.me)
        outcome, record, plan = app.store.with_occupants_lock { purge(name, by) }
        json? ? print_json(document(name, outcome, record, plan)) : report(name, outcome, record, plan)
      rescue Refusal => e
        print_json(e.record) if json?
        raise
      end

      private

      def local_name(text)
        address = text.include?('@') ? Address.parse(text) : Address.from_name(text, host: app.host)
        if address.session
          refuse(address, 'session',
                 "#{address} is one session of #{address.stable}, and purge takes only the address itself")
        end
        unless address.local?(app.host)
          refuse(address, 'remote', "purge runs on the machine that holds the address; run 'keryx purge " \
                                    "#{address.key}' on #{address.host}", 'host' => address.host)
        end

        refuse_scope(address)
        refuse(address, 'no_address', "no address #{address}") unless app.store.address?(address.key)
        address.key
      end

      def refuse_scope(address)
        if address.flat?
          refuse(address, 'no_team', "#{address} names no team, as an address from before team names does, whose " \
                                     'folder keryx keeps as the keryx of that time wrote it; purge takes MEMBER.TEAM ' \
                                     'or MEMBER.TEAM@HOST')
        end
        return unless address.reserved?

        refuse(address, 'reserved', "#{address} is in a reserved scope: NAME.#{Address::LOCAL} is a person at a " \
                                    "terminal, and keryx.#{Address::SYSTEM} is keryx itself, so purge takes neither")
      end

      def refuse(address, reason, message, fields = {})
        raise Refusal.new(message, address: address.to_s, reason:, fields:)
      end

      # The checks, the mark and the removal share one hold of the occupants lock, so a join --revive lands wholly
      # before them or after. The record is read again after the removal, as retired.json then holds it.
      def purge(name, by)
        refuse_link(name)
        record = app.store.retired(name) or
          refuse(app.full(name), 'not_retired', "#{app.full(name)} is not retired; 'keryx retire #{name}' comes first")
        plan = checked_plan(name, record)
        return [:dry_run, record, plan] if options[:dry_run]

        outcome = record.purged? ? :finished : :purged
        app.store.purge(name, plan, by:, now: app.now)
        [outcome, app.store.retired(name), plan]
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

        refuse(app.full(name), 'linked',
               "#{File.join(Store::ADDRESSES, name)} is a symbolic link; purge removes only what a folder of the " \
               'store holds, and changed nothing')
      end

      def refuse_purged(name, record)
        refuse(app.full(name), 'purged_already', "#{app.full(name)} was purged already, at #{record.purge_stamp}",
               record.record.slice('purged_at', 'purged_by'))
      end

      # A reply to the address cannot reach it once it is retired, and --as refuses to act as it, so only the sender of
      # a request to it settles one, and one it sent waits for the address to come back.
      def refuse_waiting(name, received, sent)
        count = received.size + sent.size
        return if count.zero?

        hints = received.map { answer_hint(it) } + sent.map { reply_hint(name, it) }
        refuse(app.full(name), 'waiting',
               "#{app.full(name)} has #{count} open request#{'s' unless count == 1} and is purged once none is left: " \
               "#{hints.join('; ')}",
               'received' => received.map { { 'id' => it.id, 'from' => it.from } },
               'sent' => sent.map { { 'id' => it.id, 'to' => it.to } })
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
        refuse(app.full(name), 'queued',
               "#{app.full(name)} has #{count} message#{'s' unless count == 1} waiting in the outbox #{where}; purge " \
               'runs once keryx courier forwarded or refused each, as keryx status shows under NOT FORWARDED',
               'queued' => waiting.map { |host, ids| { 'host' => host, 'ids' => ids } })
      end

      # By host, the ids of the messages from NAME that wait in the outbox, for each host that has any.
      def queued(name)
        outbox = app.store.outbox
        queued = outbox.hosts.to_h { |host| [host, outbox.queued(host).select { sent_by?(it, name) }.map(&:id)] }
        queued.reject { |_host, ids| ids.empty? }
      end

      def sent_by?(message, name) = Address.parse(message.from).key == name

      def document(name, outcome, record, plan)
        { 'address' => app.full(name), 'outcome' => outcome.to_s, 'retired_at' => record.retired_at.utc.iso8601,
          'retired_by' => record.by, 'purged_at' => record.purged_at&.utc&.iso8601, 'purged_by' => record.purged_by,
          'removed' => counts(plan), 'answers_kept' => plan.kept.size }
      end

      def counts(plan) = REMOVED.transform_values { plan.removed[it].size }

      def report(name, outcome, record, plan)
        address = terminal.paint(:address, app.full(name))
        case outcome
        when :dry_run
          terminal.puts("Purging #{address} would remove #{removed(plan)}#{kept(plan, 'keep')}. Nothing was removed.")
        when :finished
          terminal.puts("Finished purging #{address}, purged at #{record.purge_stamp}, removing #{removed(plan)}, " \
                        'which a purge cut short left or which arrived after it.')
        else
          terminal.puts("Purged #{address}, removing #{removed(plan)}#{kept(plan, 'keeping')}. Its name stays " \
                        "retired; 'keryx join #{name} --revive' takes it back without that mail.")
        end
        nil
      end

      def removed(plan)
        counts = counts(plan)
        [counted(counts['messages'], 'message'), counted(counts['read_marks'], 'read mark'),
         counted(counts['receipts'], 'receipt')].join(', ') +
          " and #{counted(counts['being_written'], 'file')} being written"
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
