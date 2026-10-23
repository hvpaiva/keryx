# frozen_string_literal: true

require_relative '../cli/command'
require_relative 'delivery'

module Keryx
  module Commands
    class Reply < CLI::Command
      define 'reply', section: 'Mail Commands', arguments: 'ID [TEXT]', min: 1, max: 2,
                      summary: 'Answer a message',
                      description: 'Answer a message in your mailbox. The reply goes to its sender in the same ' \
                                   "thread, and a request counts as answered once its recipient replies to it.\n\n" \
                                   'Replying also marks the message as read.',
                      examples: [['Answer a request', 'reply 01JB8Y2Q "Approved, with two comments on the PR"'],
                                 ['Answer with a file', 'reply 01JB8Y2Q --file review.md']]

      def define_options(parser) = body_option(parser)

      def call(arguments)
        name = app.me
        original = app.store.find(name, arguments[0]).message
        posted = answer(name, original, body(arguments[1]))
        terminal.puts("Replied to #{original.from} (#{terminal.paint(:id, posted.message.id)}). " \
                      "#{Delivery.note(posted)}")
      end

      private

      def answer(name, original, text)
        app.store.mark_read(name, original.id)
        app.postman.post(sender: name, recipient: Address.parse(original.from), kind: 'reply', body: text,
                         reply_to: original)
      end
    end
  end
end
