# frozen_string_literal: true

require_relative '../cli/command'
require_relative 'delivery'
require_relative 'wait'

module Keryx
  module Commands
    class Withdraw < CLI::Command
      define 'withdraw', section: 'Mail Commands', arguments: 'ID [TEXT]', min: 1, max: 2,
                         summary: 'Withdraw a request you sent',
                         description: "Withdraw a request you sent that no longer needs an answer.\n\n" \
                                      "The recipient gets a withdrawal in the request's thread and its bell rings. " \
                                      'From then on the request is not open, so keryx status no longer lists it, ' \
                                      'the stop hook no longer reminds the recipient of it, and keryx wait returns ' \
                                      'with the withdrawal. A reply that comes later is still delivered. TEXT says ' \
                                      "why, and without it the withdrawal says that no reply is needed.\n\n" \
                                      'A request this machine sent under a name it had before counts as sent by the ' \
                                      'address of the same name.',
                         examples: [['Withdraw a request that is no longer needed', 'withdraw 01JB8Y2Q'],
                                    ['Say why', 'withdraw 01JB8Y2Q "Fixed upstream, no need to port it"']]

      def define_options(parser) = body_option(parser)

      def call(arguments)
        holder, request = Wait.sent_request(app, app.me, arguments[0])
        refuse_settled(request)
        posted = app.postman.withdraw(request, holder:, body: text(arguments[1], request))
        terminal.puts("Withdrew #{request.id}, sent to #{request.to} (#{terminal.paint(:id, posted.message.id)}). " \
                      "#{Delivery.note(posted)}")
      end

      private

      def text(argument, request)
        return body(argument) if argument || options[:file]

        format(Message::WITHDRAWN, id: request.id)
      end

      def refuse_settled(request)
        settled = app.roster.settlement(request) or return
        raise Error, "#{request.id} was withdrawn already (#{settled.id})" if settled.withdrawal?

        raise Error, "#{request.id} is answered already (#{settled.id}); there is nothing to withdraw"
      end
    end
  end
end
