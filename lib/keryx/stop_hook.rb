# frozen_string_literal: true

require_relative 'identity'
require_relative 'roster'

module Keryx
  # Claude Code runs its Stop hook when a session is about to end its turn. If mail arrived that
  # the session never read, or it read a request and never answered, the hook keeps the turn
  # going once and says what is pending. Each message is reminded about once, so the hook cannot
  # hold a session in a loop.
  class StopHook
    UNREAD_MARK = 'nudge'
    UNANSWERED_MARK = 'reply-nudge'

    def initialize(store:, herdr:, caller:)
      @store = store
      @herdr = herdr
      @caller = caller
    end

    # The JSON object Claude Code reads from the hook's output, or nil to let the turn end.
    def decide(payload)
      caller = @caller.with(harness: 'claude', session_id: payload['session_id'] || @caller.session_id)
      name = Identity.new(store: @store, caller:, env: {}).held or return nil

      unread = @store.unread(name).select { @store.mark_once(name, it.id, UNREAD_MARK) }
      unanswered = unanswered_requests(name).select { @store.mark_once(name, it.id, UNANSWERED_MARK) }
      return nil if unread.empty? && unanswered.empty?

      { 'decision' => 'block', 'reason' => reason(name, unread, unanswered) }
    end

    private

    def unanswered_requests(name)
      Roster.new(store: @store, herdr: @herdr).open_requests.filter_map do |holder, stored|
        stored.message if holder == name && stored.state == :read
      end
    end

    def reason(name, unread, unanswered)
      parts = []
      parts << "#{count(unread.size, 'unread message')} (#{ids(unread)})" unless unread.empty?
      unless unanswered.empty?
        parts << "#{count(unanswered.size, 'request')} read but not answered (#{ids(unanswered, from: true)})"
      end
      "keryx: #{name} has #{parts.join(' and ')}. Open each with 'keryx read ID' and answer every request with " \
        "'keryx reply ID TEXT' before ending the turn; if a request cannot be done, reply saying why."
    end

    def count(number, noun) = "#{number} #{noun}#{'s' unless number == 1}"

    def ids(messages, from: false)
      messages.map { from ? "#{it.id} from #{it.from}" : it.id }.join(', ')
    end
  end
end
