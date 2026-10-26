# frozen_string_literal: true

require_relative '../address'
require_relative '../archive'
require_relative '../cli/command'
require_relative '../cli/mailbox_view'
require_relative '../cli/message_view'
require_relative '../cli/sent_list'
require_relative '../cli/table'

module Keryx
  module Commands
    class History < CLI::Command
      include CLI::SentList

      RETIRED_HEADERS = ['ADDRESS', 'RETIRED', 'BY', 'MAIL', 'LAST MAIL', 'PURGED'].freeze
      FORMS = 'history takes MEMBER.TEAM, MEMBER.TEAM@HOST, or MEMBER@HOST for an address from before team names'

      define 'history', section: 'Mail Commands', arguments: '[ADDRESS]', max: 1,
                        summary: 'List the retired addresses, or the mail of one',
                        description: 'List the mail of a retired address on this machine, read and unread, oldest ' \
                                     "first, or with --sent what it sent.\n\n" \
                                     'With no ADDRESS, history lists the retired addresses on this machine instead, ' \
                                     'in name order, so whoever chooses what keryx purge removes sees when each was ' \
                                     'retired and last had mail: ADDRESS, RETIRED and BY, when and by which address ' \
                                     'it was retired, MAIL, the messages its mailbox holds, read and unread, LAST ' \
                                     'MAIL, when the newest of them was written, and PURGED, when keryx purge ' \
                                     'removed its mail. -o json prints an array with one object per address, with ' \
                                     'address, retired_at, retired_by, mail, last_mail_at, purged_at and purged_by, ' \
                                     'times in ISO 8601 and null where there is none. Folders from before team names ' \
                                     'are left out, since keryx purge takes none of them and history MEMBER@HOST ' \
                                     "reads each.\n\n" \
                                     'history acts as no address, so it needs no session, --as changes nothing, ' \
                                     'and it marks nothing read and sends nothing. ADDRESS is MEMBER.TEAM or ' \
                                     'MEMBER.TEAM@HOST for an address keryx retire retired, which no command acts ' \
                                     'as with --as; one that is not retired is refused, since keryx inbox --all ' \
                                     '--as ADDRESS lists it. ADDRESS is MEMBER@HOST for an address from before team ' \
                                     'names, retired or not, whose folder, addresses/MEMBER in the keryx state ' \
                                     'directory, keryx keeps as the keryx of that time wrote it. history is the one ' \
                                     'command that takes MEMBER@HOST and the one that reads that folder, by name ' \
                                     'and without changing it, its mail of message format 1 included. An address ' \
                                     "on another machine is read there.\n\n" \
                                     'Once keryx purge removed the mail of an address, history ADDRESS lists only ' \
                                     'the answers to the requests it sent, which purge keeps, and says when its mail ' \
                                     'was purged, so whatever shows that history, such as a page, shows less, with ' \
                                     "no error.\n\n" \
                                     'Each message lists with its STATE, unread or read, as keryx inbox --all lists ' \
                                     'it, and with -o json it prints an array with one object per message, the ' \
                                     'message with state, as keryx inbox --all -o json does. ' \
                                     "#{CLI::MessageView::JSON_HELP}\n\n" \
                                     'With --sent it lists what the address sent from this machine as keryx sent ' \
                                     'lists it, with the same columns, fields and filters; for MEMBER@HOST that ' \
                                     'takes in the folders from before team names and message format 1 in the ' \
                                     "outbox. #{CLI::SentList::FILTERS} --to takes an address as ADDRESS does, or " \
                                     "MEMBER alone for a member of the same team. #{CLI::SentList::COLUMNS} " \
                                     "#{CLI::SentList::JSON_FIELDS}\n\n#{SCHEMA_HELP}",
                        examples: [['List the retired addresses, with when each last had mail', 'history'],
                                   ['Read back the mail of a retired reviewer', 'history rev-1.alpha'],
                                   ['List what an address from before team names sent, as JSON',
                                    'history hvpaiva@athena --sent -o json']]

      def define_options(parser)
        parser.on('--sent', 'List what the address sent instead') { options[:sent] = true }
        sent_options(parser)
        output_option(parser)
      end

      def call(arguments)
        return list_retired if arguments.empty?

        if !options[:sent] && options.keys.intersect?(%i[id thread to])
          raise UsageError, '--id, --thread and --to narrow what --sent lists; add --sent'
        end

        archive = Archive.new(app.store, old: true)
        address = subject(arguments.first, archive)
        return list_sent(archive, address.to_s) { recipient(it, address) } if options[:sent]

        list(archive, address)
      end

      private

      def subject(text, archive)
        address = parse(text)
        unless address.local?(app.host)
          raise Error, "#{address} is on another machine; run 'keryx history #{address}' on #{address.host}"
        end

        address.flat? ? old(address, archive) : retired(address)
        address
      end

      def parse(text)
        address = text.include?('@') ? Address.parse(text) : Address.from_name(text, host: app.host)
        raise UsageError, "#{FORMS}; #{text} names neither" if address.flat? && !text.include?('@')
        return address unless address.session

        raise Error, "#{address} is one session of #{address.stable}, and history takes only the address itself"
      end

      def old(address, archive)
        raise Error, "no address #{address}" unless archive.old?(address.member)
      end

      def retired(address)
        key = address.key
        raise Error, "no address #{address}" unless app.store.address?(key)
        return if app.store.retired?(key)

        command, lists = options[:sent] ? ["sent --as #{key}", 'what it sent'] : ["inbox --all --as #{key}", 'it']
        raise Error, "#{address} is not retired; 'keryx #{command}' lists #{lists}"
      end

      def recipient(text, address)
        text.include?('@') ? Address.parse(text) : app.resolver.resolve(text, sender: address.key)
      end

      def list(archive, address)
        stored = archive.held(address.key)
        withdrawn = Store.withdrawn(stored.map(&:message), stored.map(&:message))
        return print_json(CLI::MailboxView.records(stored, withdrawn)) if json?

        if stored.empty?
          terminal.puts("No messages for #{address}.")
        else
          terminal.puts(CLI::MailboxView.table(terminal, stored, withdrawn, app.now, state: true))
        end
        purged(address)
      end

      def list_retired
        if options.keys.intersect?(%i[sent id thread to])
          raise UsageError, '--sent, --id, --thread and --to read one address; give ADDRESS'
        end

        rows = retired_rows
        return print_json(rows.map { |row| row.transform_values { it.is_a?(Time) ? it.utc.iso8601 : it } }) if json?
        return terminal.puts("No retired addresses on #{app.host}.") if rows.empty?

        terminal.puts(CLI::Table.render(terminal, RETIRED_HEADERS, rows.map { retired_cells(it) }))
      end

      # A retired address whose record cannot be read is reported as a problem and left out.
      def retired_rows
        app.store.address_names.select { app.store.retired?(it) }
           .filter_map { |name| app.store.reporting { retired_row(name) } }
      end

      def retired_row(name)
        record = app.store.retired(name)
        messages = app.store.stored(name).map(&:message)
        { 'address' => app.full(name), 'retired_at' => record.retired_at, 'retired_by' => record.by,
          'mail' => messages.size, 'last_mail_at' => messages.max_by(&:id)&.created_at,
          'purged_at' => record.purged_at, 'purged_by' => record.purged_by }
      end

      def retired_cells(row)
        [[:address, row['address']], ago(row['retired_at']), [:address, row['retired_by']], row['mail'].to_s,
         ago(row['last_mail_at']), ago(row['purged_at'])]
      end

      def ago(time) = time ? "#{age(time)} ago" : '-'

      def purged(address)
        return if address.flat?

        record = app.store.reporting { app.store.retired(address.key) }
        return unless record&.purged?

        terminal.puts("#{address} was purged at #{record.purge_stamp}; history lists only the answers to the " \
                      'requests it sent, which purge keeps.')
      end
    end
  end
end
