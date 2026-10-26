# frozen_string_literal: true

require_relative '../cli/command'
require_relative 'delivery'
require_relative 'wait'

module Keryx
  module Commands
    class Send < CLI::Command
      MISSING = "missing ADDRESS; give the address, --re ID to send in a request's thread, " \
                'or --on ID to add to a request you sent'
      OUTSIDE = "'keryx send ADDRESS' sends a message outside its thread"
      BOTH = '--on and --re send in different directions; use only one'
      ON_ADDRESS = "--on sends to the request's recipient; leave out ADDRESS"

      define 'send', section: 'Mail Commands', arguments: '(ADDRESS | --re ID | --on ID) [TEXT]', max: 2,
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
                                  'an id that is not a request; keryx reply answers any message in its thread. ' \
                                  'Neither goes to an address from before team names, MEMBER@HOST, which keryx ' \
                                  "no longer writes to.\n\n" \
                                  '--on ID adds to a request you sent, in its thread and to its original recipient, ' \
                                  'and takes no ADDRESS. The message does not mark the request read or taken, and ' \
                                  'the request stays open until the recipient replies or you withdraw it. A request ' \
                                  'already answered or withdrawn is refused, and so are an id you did not send and ' \
                                  'a request to your own address, which keryx reply answers and keryx withdraw ' \
                                  'closes.',
                     examples: [['Tell the orchestrator a task is done', 'send orq "PR #448 reviewed and approved"'],
                                ['Send the contents of a file', 'send orq --file report.md'],
                                ['Say you took a request whose work goes on', 'send --re 01JB8Y2Q "On it, PR by 3pm"'],
                                ['Add to a request you sent', 'send --on 01JB8Y2Q "The fixture is reset"']]

      def define_options(parser)
        body_option(parser)
        parser.on('--re ID', 'Send in the thread of request ID in your mailbox, to its sender') do |id|
          options[:re] = id
        end
        parser.on('--on ID', 'Add to request ID you sent, in its thread, without answering it') do |id|
          options[:on] = id
        end
      end

      def call(arguments)
        return along_thread(arguments) if options[:on] || options[:re]

        plain(arguments)
      end

      private

      def plain(arguments)
        raise UsageError, MISSING if arguments.empty?

        posted = app.postman.post(sender: app.me, recipient: app.address(arguments[0]), kind: 'message',
                                  body: body(arguments[1]))
        terminal.puts("Sent #{terminal.paint(:id, posted.message.id)} to #{posted.message.to}. " \
                      "#{Delivery.note(posted)}")
        nil
      end

      def along_thread(arguments)
        raise UsageError, BOTH if options[:on] && options[:re]
        return in_thread(arguments) if options[:re]

        add_to(arguments)
      end

      def in_thread(arguments)
        raise UsageError, "--re sends to the request's sender; leave out ADDRESS" if arguments.size > 1

        request = open_request(app.me, options[:re])
        told(take(request, body(arguments[0])), request)
      end

      def add_to(arguments)
        raise UsageError, ON_ADDRESS if arguments.size > 1

        holder, request = Wait.sent_request(app, app.me, options[:on])
        refuse_own(request, holder)
        refuse_closed(request)
        told(complement(request, holder, body(arguments[0])), request)
      end

      # An addition to a request to one's own address would read as its recipient taking it, and adds for no one.
      def refuse_own(request, holder)
        return unless holder && Address.parse(request.to).key == Address.from_name(app.me, host: app.host).key

        raise Error, "#{request.id} is a request to your own address, so there is no one to add to; answer it with " \
                     "'keryx reply #{request.id}' or close it with 'keryx withdraw #{request.id}'"
      end

      # A request held in a mailbox here goes to its recipient here, though it may name this machine by a name it no
      # longer has; one in the outbox goes to the machine it names.
      def complement(request, holder, text)
        recipient = Address.parse(request.to)
        recipient = recipient.with(host: app.host) if holder
        app.postman.post(sender: app.me, recipient:, kind: 'message', body: text, reply_to: request)
      end

      def told(posted, request)
        terminal.puts("Sent #{terminal.paint(:id, posted.message.id)} to #{posted.message.to} in the thread of " \
                      "#{terminal.paint(:id, request.id)}. #{Delivery.note(posted)}")
      end

      def refuse_closed(request)
        settled = app.roster.settlement(request) or return

        state = settled.withdrawal? ? 'withdrawn' : 'already answered'
        raise Error, "#{request.id} is #{state} by #{settled.id}; #{OUTSIDE}"
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
