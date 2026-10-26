# frozen_string_literal: true

require_relative '../address'
require_relative '../error'
require_relative '../store'
require_relative 'message_view'
require_relative 'table'

module Keryx
  module CLI
    # What an address sent, as keryx sent lists it for the address it acts as, in the command that includes it.
    module SentList
      HEADERS = %w[ID TO AGE KIND DELIVERY READ SUMMARY].freeze
      FILTERS = '--id and --thread take a message id or its first characters, at least four, and keep the message ' \
                'with that id or the messages of that thread. --to keeps the messages to ADDRESS, whichever session ' \
                'of it they reached. The three combine.'
      COLUMNS = 'DELIVERY is delivered for a recipient on this machine, and queued, forwarded or refused for one on ' \
                'another, as the outbox has it: queued waits for keryx courier, forwarded reached that machine, and ' \
                'refused never will. READ is how long ago the recipient marked the message read, - while it is ' \
                'unread, and ? for a recipient on another machine, which keeps its read marks to itself.'
      JSON_FIELDS = 'With -o json it prints an array with one object per message, the message with delivery and, for ' \
                    'a recipient on this machine, read_at, the time of the read mark in ISO 8601 UTC, or null while ' \
                    'unread. read_at is the change time of the read mark, a hard link to the message that keryx read ' \
                    'makes and nothing changes after, so a copy of the store, such as cp -a or a restored backup, ' \
                    'sets it to the time of the copy.'

      private

      def sent_options(parser)
        parser.on('--id REF', 'Only the message whose id starts with REF') { options[:id] = reference(it) }
        parser.on('--thread REF', 'Only the thread whose id starts with REF') { options[:thread] = reference(it) }
        parser.on('--to ADDRESS', 'Only the messages to ADDRESS') { options[:to] = it }
      end

      # What SENDER, a stable address, sent, as ARCHIVE reads it; the block turns the text of --to into an address.
      def list_sent(archive, sender, &)
        sent = archive.sent_by(sender)
        listed = narrowed(sent, &)
        return print_json(sent_records(sent, listed)) if json?
        return terminal.puts("No messages sent by #{sender}#{' match' unless sent.empty?}.") if listed.empty?

        terminal.puts(Table.render(terminal, HEADERS, listed.map { sent_row(it) }))
      end

      def reference(text)
        Store.reference(text)
      rescue Error => e
        raise UsageError, e.message
      end

      def narrowed(sent)
        to = options[:to] && yield(options[:to]).stable.to_s
        sent.select do |item|
          message = item.message
          message.id.start_with?(options[:id].to_s) && message.thread.start_with?(options[:thread].to_s) &&
            (to.nil? || Address.parse(message.to).stable.to_s == to)
        end
      end

      # A withdrawal the filters leave out still names the request it withdrew.
      def sent_records(sent, listed)
        withdrawn = Store.withdrawn(listed.map(&:message), sent.map(&:message))
        listed.map { sent_record(it, withdrawn[it.message.id]) }
      end

      def sent_record(sent, withdrawal)
        record = MessageView.record(sent.message, withdrawal).merge('delivery' => sent.delivery)
        sent.here? ? record.merge('read_at' => sent.read_at&.iso8601) : record
      end

      def sent_row(sent)
        message = sent.message
        [[:id, message.id], message.to, age(message.created_at),
         message.request? ? [:request, message.kind] : message.kind,
         sent.here? ? sent.delivery : [sent.delivery.to_sym, sent.delivery], read(sent), message.summary]
      end

      def read(sent)
        return '?' unless sent.here?

        sent.read_at ? age(sent.read_at) : '-'
      end
    end
  end
end
