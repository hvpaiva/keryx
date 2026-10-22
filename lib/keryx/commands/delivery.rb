# frozen_string_literal: true

module Keryx
  module Commands
    # What the commands that post a message say about its bell.
    module Delivery
      module_function

      def note(posted)
        bell = posted.bell
        return 'It went to your own mailbox, so no bell rang.' unless bell

        case bell.status
        when Bell::RUNG then "The bell rang through #{bell.channel}."
        when Bell::ABSENT then "No session holds #{posted.message.to}; the message waits in its mailbox."
        else "The bell #{bell.status == Bell::DEFERRED ? 'is deferred' : 'failed'} (#{bell.detail}); " \
             "the message waits in the mailbox and 'keryx ring' tries again."
        end
      end
    end
  end
end
