# frozen_string_literal: true

require_relative '../address'
require_relative '../archive'
require_relative '../cli/command'
require_relative '../cli/message_view'
require_relative '../cli/sent_list'

module Keryx
  module Commands
    class Sent < CLI::Command
      include CLI::SentList

      define 'sent', section: 'Mail Commands',
                     summary: 'List the messages you sent',
                     description: 'List the messages the address you act as sent, oldest first, and where each ' \
                                  "is.\n\n" \
                                  'They are found in every mailbox on this machine, a retired one included, and in ' \
                                  'the outbox for another machine, a refused message included. What a session that ' \
                                  'join --force displaced from the address sent is listed too, and so is each ' \
                                  "withdrawal, as a message of its own.\n\n" \
                                  "#{CLI::SentList::FILTERS} #{ADDRESS_FORMS}\n\n#{CLI::SentList::COLUMNS}\n\n" \
                                  "#{CLI::SentList::JSON_FIELDS} #{CLI::MessageView::JSON_HELP}\n\n#{SCHEMA_HELP}",
                     examples: [['See what you sent and whether it was read', 'sent'],
                                ['Follow one thread', 'sent --thread 01JB8Y2Q'],
                                ['List what you sent to a reviewer as JSON', 'sent --to rev-1 -o json']]

      def define_options(parser)
        sent_options(parser)
        output_option(parser)
      end

      def call(_arguments)
        sender = Address.from_name(app.me, host: app.host).stable.to_s
        list_sent(Archive.new(app.store), sender) { app.address(it) }
      end
    end
  end
end
