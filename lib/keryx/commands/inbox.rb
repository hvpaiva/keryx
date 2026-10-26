# frozen_string_literal: true

require_relative '../cli/command'
require_relative '../cli/mailbox_view'
require_relative '../cli/message_view'

module Keryx
  module Commands
    class Inbox < CLI::Command
      define 'inbox', section: 'Mail Commands',
                      summary: 'List the messages waiting for you',
                      description: "List the unread messages of the address you act as, oldest first.\n\n" \
                                   'Listing does not mark anything as read; keryx read does. With --all the read ' \
                                   "messages are listed too.\n\n" \
                                   'With -o json it prints an array with one object per message, the message with ' \
                                   "state, unread or read. #{CLI::MessageView::JSON_HELP}\n\n#{SCHEMA_HELP}",
                      examples: [['See what arrived', 'inbox'], ['List everything as JSON', 'inbox --all -o json']]

      def define_options(parser)
        parser.on('-a', '--all', 'List read messages too') { options[:all] = true }
        output_option(parser)
      end

      def call(_arguments)
        stored = listed
        withdrawn = app.store.withdrawals(app.me, stored.map(&:message))
        return print_json(CLI::MailboxView.records(stored, withdrawn)) if json?
        return terminal.puts(nothing) if stored.empty?

        terminal.puts(CLI::MailboxView.table(terminal, stored, withdrawn, app.now, state: options[:all]))
      end

      private

      def nothing = "No #{'unread ' unless options[:all]}messages for #{app.full(app.me)}."

      def listed
        return app.store.mailbox(app.me) if options[:all]

        app.store.unread(app.me).map { StoredMessage.new(it, :unread) }
      end
    end
  end
end
