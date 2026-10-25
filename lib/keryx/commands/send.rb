# frozen_string_literal: true

require_relative '../cli/command'
require_relative 'delivery'

module Keryx
  module Commands
    class Send < CLI::Command
      MISSING = "missing ADDRESS; give the address, or --re ID to send in a request's thread"
      OUTSIDE = "'keryx send ADDRESS' sends a message outside its thread"

      define 'send', section: 'Mail Commands', arguments: '(ADDRESS | --re ID) [TEXT]', max: 2,
                     summary: 'Send a message that needs no reply',
                     description: "Send a message that needs no reply, such as a status update or a heads-up.\n\n" \
                                  'The text comes from the argument or from a file with --file, and from standard ' \
                                  'input when either is -. ' \
                                  "Use ask instead when you need an answer.\n\n#{ADDRESSING}\n\n" \
                                  '--re ID sends the message to the sender of request ID in your mailbox, in its ' \
                                  'thread, and takes no ADDRESS. It marks the request read and says you took it: ' \
                                  'keryx status shows the request as taken, and the stop hook no longer reminds you ' \
                                  'of it. The request stays open, and its sender keeps waiting, until you answer it ' \
                                  'with keryx reply. A request already answered or withdrawn is refused, and so is ' \
                                  'an id that is not a request; keryx reply answers any message in its thread, ' \
                                  'except in a thread with an address from before team names, where it answers ' \
                                  'only the request while it is open and is refused otherwise, on this machine and ' \
                                  'from another.',
                     examples: [['Tell the orchestrator a task is done', 'send orq "PR #448 reviewed and approved"'],
                                ['Send the contents of a file', 'send orq --file report.md'],
                                ['Say you took a request whose work goes on', 'send --re 01JB8Y2Q "On it, PR by 3pm"']]

      def define_options(parser)
        body_option(parser)
        parser.on('--re ID', 'Send in the thread of request ID in your mailbox, to its sender') do |id|
          options[:re] = id
        end
      end

      def call(arguments)
        return in_thread(arguments) if options[:re]
        raise UsageError, MISSING if arguments.empty?

        posted = app.postman.post(sender: app.me, recipient: app.address(arguments[0]), kind: 'message',
                                  body: body(arguments[1]))
        terminal.puts("Sent #{terminal.paint(:id, posted.message.id)} to #{posted.message.to}. " \
                      "#{Delivery.note(posted)}")
        nil
      end

      private

      def in_thread(arguments)
        raise UsageError, "--re sends to the request's sender; leave out ADDRESS" if arguments.size > 1

        request = open_request(app.me, options[:re])
        posted = take(request, body(arguments[0]))
        terminal.puts("Sent #{terminal.paint(:id, posted.message.id)} to #{posted.message.to} in the thread of " \
                      "#{terminal.paint(:id, request.id)}. #{Delivery.note(posted)}")
      end

      # The request is marked read once the message is posted, so a message that fails leaves it as it was.
      def take(request, text)
        app.postman.post(sender: app.me, recipient: Address.parse(request.from), kind: 'message', body: text,
                         reply_to: request).tap { app.store.mark_read(app.me, request.id) }
      end

      def open_request(name, reference)
        message = app.store.find(name, reference).message
        unless message.request?
          raise Error, "#{message.id} is a #{message.kind}, not a request; 'keryx reply ID' answers it in its thread"
        end

        settled = app.roster.settlement(message) or return message
        state = settled.withdrawal? ? 'withdrawn' : 'already answered'
        raise Error, "#{message.id} is #{state} by #{settled.id}; #{OUTSIDE}"
      end
    end
  end
end
