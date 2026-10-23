# frozen_string_literal: true

require_relative '../cli/command'
require_relative '../cli/message_view'
require_relative '../cli/table'

module Keryx
  module Commands
    class Inbox < CLI::Command
      define 'inbox', section: 'Mail Commands',
                      summary: 'List the messages waiting for you',
                      description: "List the unread messages of the address you act as, oldest first.\n\n" \
                                   'Listing does not mark anything as read; keryx read does. With --all the read ' \
                                   'messages are listed too.',
                      examples: [['See what arrived', 'inbox'], ['List everything as JSON', 'inbox --all -o json']]

      def define_options(parser)
        parser.on('-a', '--all', 'List read messages too') { options[:all] = true }
        output_option(parser)
      end

      def call(_arguments)
        stored = listed
        withdrawn = app.store.withdrawals(app.me, stored.map(&:message))
        return print_json(stored.map { record(it, withdrawn) }) if json?
        return terminal.puts(nothing) if stored.empty?

        terminal.puts(CLI::Table.render(terminal, headers, stored.map { row(it, withdrawn) }))
      end

      private

      def nothing = "No #{'unread ' unless options[:all]}messages for #{app.full(app.me)}."

      def listed
        return app.store.mailbox(app.me) if options[:all]

        app.store.unread(app.me).map { StoredMessage.new(it, :unread) }
      end

      def headers = %w[ID KIND FROM AGE DUE] + (options[:all] ? ['STATE'] : []) + ['SUMMARY']

      def record(stored, withdrawn)
        CLI::MessageView.record(stored.message, withdrawn[stored.message.id]).merge('state' => stored.state.to_s)
      end

      def row(stored, withdrawn)
        message = stored.message
        cells = [[:id, message.id], message.request? ? [:request, message.kind] : message.kind, message.from,
                 age(message.created_at), due(message, withdrawn[message.id])]
        cells << [stored.state, stored.state.to_s] if options[:all]
        cells << message.summary
      end

      def due(message, withdrawal)
        return [:muted, 'withdrawn'] if withdrawal

        due = CLI::MessageView.due(message, app.now)
        due.start_with?('overdue') ? [:overdue, due] : due
      end
    end
  end
end
