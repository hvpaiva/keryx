# frozen_string_literal: true

require_relative '../cli/command'
require_relative 'delivery'

module Keryx
  module Commands
    class Send < CLI::Command
      define 'send', section: 'Mail Commands', arguments: 'ADDRESS [TEXT]', min: 1, max: 2,
                     summary: 'Send a message that needs no reply',
                     description: "Send a message that needs no reply, such as a status update or a heads-up.\n\n" \
                                  'The text comes from the argument or from a file with --file, and from standard ' \
                                  'input when either is -. ' \
                                  'Use ask instead when you need an answer.',
                     examples: [['Tell the orchestrator a task is done', 'send orq "PR #448 reviewed and approved"'],
                                ['Send the contents of a file', 'send orq --file report.md']]

      def define_options(parser) = body_option(parser)

      def call(arguments)
        posted = app.postman.post(sender: app.me, recipient: app.address(arguments[0]), kind: 'message',
                                  body: body(arguments[1]))
        terminal.puts("Sent #{terminal.paint(:id, posted.message.id)} to #{posted.message.to}. " \
                      "#{Delivery.note(posted)}")
        nil
      end
    end
  end
end
