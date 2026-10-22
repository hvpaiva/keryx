# frozen_string_literal: true

require_relative '../cli/command'
require_relative '../cli/message_view'
require_relative '../duration'

module Keryx
  module Commands
    class Wait < CLI::Command
      POLL_SECONDS = 1

      define 'wait', section: 'Mail Commands', arguments: 'ID', min: 1, max: 1,
                     summary: 'Block until a request you sent is answered',
                     description: 'Block until the request ID, which you sent, is answered, then show the reply ' \
                                  "and mark it as read.\n\n" \
                                  'An agent rarely needs this: the reply rings its session when it arrives. It is ' \
                                  'for scripts, and for work that cannot go on without the answer. It exits with ' \
                                  'status 3 when --timeout passes first.',
                     examples: [['Wait at most ten minutes for a review', 'wait 01JB8Y2Q --timeout 10m']]

      def define_options(parser)
        parser.on('--timeout DURATION', 'Give up after DURATION, such as 90s or 10m (default: wait forever)') do |time|
          options[:timeout] = time
        end
        output_option(parser)
      end

      def call(arguments)
        name = app.me
        reply = poll(name, sent_request(name, arguments.first), deadline)
        app.store.mark_read(name, reply.id)
        show_message(reply)
      end

      private

      def deadline = options[:timeout] && (app.now + Duration.parse(options[:timeout]))

      def sent_request(name, reference)
        reference = Store.reference(reference)
        mine = requests_from(app.full(name)).select { it.id.start_with?(reference) }
        return mine.first if mine.one?

        raise Error, "#{reference} matches #{mine.size} requests you sent; type more of the id" if mine.size > 1

        raise Error, "no request #{reference} sent by #{app.full(name)}"
      end

      def requests_from(address)
        app.store.all_messages.map { it.last.message }.select { it.from == address && it.request? }
      end

      def poll(name, request, deadline)
        loop do
          reply = app.store.mailbox(name).map(&:message).find { it.in_reply_to == request.id }
          return reply if reply
          raise WaitTimeout, "no reply to #{request.id} from #{request.to} yet" if deadline && app.now >= deadline

          app.sleeper.call(POLL_SECONDS)
        end
      end
    end
  end
end
