# frozen_string_literal: true

module Keryx
  module Commands
    module Delivery
      module_function

      def note(posted)
        return forwarded(posted) if posted.forward
        return 'It went to your own mailbox, so no bell rang.' unless posted.bell

        bell = posted.bell
        bell_note(bell.status, bell.channel, bell.detail, posted.message.to)
      end

      def forwarded(posted)
        result = posted.forward
        host = posted.message.to.split('@').last
        if result.status == Forwarder::QUEUED
          return "#{host} did not answer (#{Text.plain(result.detail)}); the message waits in the outbox and " \
                 "'keryx courier' forwards it once #{host} is back."
        end

        bell = result.bell || {}
        "It reached #{host}. #{bell_note(bell['status'], bell['channel'], bell['detail'], posted.message.to)}"
      end

      def bell_note(status, channel, detail, to)
        case status
        when Bell::RUNG then "The bell rang through #{Text.plain(channel)}."
        when Bell::ABSENT then "No session holds #{to}; the message waits in its mailbox."
        else "The bell #{status == Bell::DEFERRED ? 'is deferred' : 'failed'} (#{Text.plain(detail)}); " \
             "the message waits in the mailbox and 'keryx ring' tries again."
        end
      end
    end
  end
end
