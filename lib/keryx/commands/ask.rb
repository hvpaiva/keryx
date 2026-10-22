# frozen_string_literal: true

require_relative '../cli/command'
require_relative '../duration'
require_relative 'delivery'

module Keryx
  module Commands
    class Ask < CLI::Command
      define 'ask', section: 'Mail Commands', arguments: 'ADDRESS [TEXT]', min: 1, max: 2,
                    summary: 'Send a request that expects a reply',
                    description: "Send a request that expects a reply.\n\n" \
                                 'The request stays open until the recipient answers it with keryx reply, and ' \
                                 'keryx status lists it while it waits. --within sets a deadline that status ' \
                                 'reports as overdue once it passes. The reply rings this session when it ' \
                                 'arrives, so there is no need to wait for it; keryx wait blocks until it comes ' \
                                 'for the cases that cannot go on without it.',
                    examples: [['Ask for a review with a deadline', 'ask rev-1 "Review PR #448" --within 30m'],
                               ['Ask with a longer brief from a file', 'ask impl --file brief.md']]

      def define_options(parser)
        body_option(parser)
        parser.on('--within DURATION', 'Expect the reply within DURATION, such as 30m or 1h30m') do |duration|
          options[:within] = duration
        end
      end

      def call(arguments)
        posted = app.postman.post(sender: app.me, recipient: app.address(arguments[0]), kind: 'request',
                                  body: body(arguments[1]), due_at:)
        terminal.puts("#{asked(posted.message)} #{Delivery.note(posted)}", follow_up(posted.message.id))
      end

      private

      def asked(message) = "Asked #{message.to} (#{terminal.paint(:id, message.id)})."

      def due_at = options[:within] && (app.now + Duration.parse(options[:within]))

      def follow_up(id)
        if app.caller.agent?
          "The reply will ring this session; 'keryx wait #{id}' blocks until it arrives."
        else
          "'keryx inbox' shows the reply when it arrives; 'keryx wait #{id}' blocks until then."
        end
      end
    end
  end
end
