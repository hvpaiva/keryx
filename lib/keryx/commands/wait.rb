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
                                  'and mark it as read. When the request is withdrawn before a reply comes, it ' \
                                  'shows the withdrawal instead. A request to an address from before team names, ' \
                                  'MEMBER@HOST, is over, since nothing can answer it any more, so wait says so at ' \
                                  "once unless its reply came before.\n\n" \
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

      # The mailbox or outbox that holds the request NAME sent, and the request.
      def self.sent_request(app, name, reference)
        reference = Store.reference(reference)
        mine = app.store.sent_requests(name).select { it.last.id.start_with?(reference) }
        return mine.first if mine.one?

        raise Error, "#{reference} matches #{mine.size} requests you sent; type more of the id" if mine.size > 1

        raise Error, "no request #{reference} sent by #{app.full(name)}"
      end

      def call(arguments)
        name = app.me
        settled = poll(name, *Wait.sent_request(app, name, arguments.first), deadline)
        app.store.mark_read(name, settled.id) if settled.reply?
        show_message(settled)
      end

      private

      def deadline = options[:timeout] && (app.monotonic.call + Duration.parse(options[:timeout]))

      def poll(name, holder, request, deadline)
        loop do
          settled = reply(name, request) || withdrawal(holder, request)
          return settled if settled

          over(request)
          raise WaitTimeout, "no reply to #{request.id} from #{request.to} yet" if passed?(deadline)

          app.sleeper.call(POLL_SECONDS)
        end
      end

      def passed?(deadline) = deadline && app.monotonic.call >= deadline

      def over(request)
        teamless = request.teamless or return

        raise Error, "#{request.id} is over and gets no reply; #{format(Address::TEAMLESS, teamless)}"
      end

      def reply(name, request) = app.store.stored(name).map(&:message).find { it.answers?(request) }

      # A withdrawal is written where its request is, in a mailbox or in the outbox for the recipient's host.
      def withdrawal(holder, request)
        held = if holder
                 app.store.stored(holder).map(&:message)
               else
                 sent = app.store.outbox.outgoing(Address.parse(request.to).host)
                 sent.reject { it.state == :refused }.map(&:message)
               end
        held.find { it.withdraws?(request) }
      end
    end
  end
end
