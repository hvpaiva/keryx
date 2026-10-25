# frozen_string_literal: true

require_relative '../cli/command'
require_relative '../cli/message_view'

module Keryx
  module Commands
    class Read < CLI::Command
      define 'read', section: 'Mail Commands', arguments: '[ID]', max: 1,
                     summary: 'Show a message and mark it as read',
                     description: "Show a message in full and mark it as read.\n\n" \
                                  'Without ID it opens the oldest unread message. ID may be the whole id or its ' \
                                  'first characters, at least four, as long as they match one message. Marking a ' \
                                  'message read is how a sender on the same machine learns you saw it, so read it ' \
                                  'with this command rather than through the files; a sender on another machine ' \
                                  "sees only that it arrived.\n\n" \
                                  'A message carries the context its sender used when it sent it, when keryx could ' \
                                  "measure it, and read shows it in the same form as keryx who.\n\n" \
                                  'A session that join --force displaced reads, without ID, only the mail to its ' \
                                  'session address. By ID it also opens the mail to the address it held, so it ' \
                                  'can finish what it took before.',
                     examples: [['Open the next unread message', 'read'], ['Open one message', 'read 01JB8Y2Q']]

      def define_options(parser) = output_option(parser)

      def call(arguments)
        name = app.me
        message = pick(name, arguments.first)
        return terminal.puts("No unread messages for #{app.full(name)}.") unless message

        app.store.mark_read(name, message.id)
        show_message(message, app.store.withdrawals(name, [message])[message.id])
      end

      private

      def pick(name, reference) = reference ? app.store.find(name, reference).message : app.store.unread(name).first
    end
  end
end
