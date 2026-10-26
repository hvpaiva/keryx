# frozen_string_literal: true

require_relative '../address'
require_relative '../archive'
require_relative '../cli/command'
require_relative '../cli/mailbox_view'
require_relative '../cli/message_view'
require_relative '../cli/sent_list'

module Keryx
  module Commands
    class History < CLI::Command
      include CLI::SentList

      FORMS = 'history takes MEMBER.TEAM, MEMBER.TEAM@HOST, or MEMBER@HOST for an address from before team names'

      define 'history', section: 'Mail Commands', arguments: 'ADDRESS', min: 1, max: 1,
                        summary: 'List the mail of a retired address',
                        description: 'List the mail of a retired address on this machine, read and unread, oldest ' \
                                     "first, or with --sent what it sent.\n\n" \
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
                        examples: [['Read back the mail of a retired reviewer', 'history rev-1.alpha'],
                                   ['List what an address from before team names sent, as JSON',
                                    'history hvpaiva@athena --sent -o json']]

      def define_options(parser)
        parser.on('--sent', 'List what the address sent instead') { options[:sent] = true }
        sent_options(parser)
        output_option(parser)
      end

      def call(arguments)
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
        return terminal.puts("No messages for #{address}.") if stored.empty?

        terminal.puts(CLI::MailboxView.table(terminal, stored, withdrawn, app.now, state: true))
      end
    end
  end
end
