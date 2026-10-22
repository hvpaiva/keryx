# frozen_string_literal: true

require_relative 'identity'
require_relative 'roster'

module Keryx
  class StopHook
    UNREAD_MARK = 'nudge'
    UNANSWERED_MARK = 'reply-nudge'

    def initialize(store:, herdr:, caller:)
      @store = store
      @herdr = herdr
      @caller = caller
    end

    # Marks reminders only after the block passed the decision on, so a hook cut off before then reminds again.
    def decide(payload)
      harness = harness_of(payload)
      name = Identity.new(store: @store, caller: session_caller(harness, payload), env: {}).held
      pending = name ? pending(name) : {}
      decision = decision(harness, reminder(name, pending)) or return

      yield decision
      pending.each { |mark, messages| messages.each { @store.mark_once(name, it.id, mark) } }
    end

    private

    def decision(harness, reminder)
      return { 'followup_message' => reminder }.compact if harness == 'cursor'

      { 'decision' => 'block', 'reason' => reminder } if reminder
    end

    def harness_of(payload)
      if payload.key?('cursor_version') then 'cursor'
      elsif payload.key?('turn_id') then 'codex'
      else 'claude'
      end
    end

    def session_caller(harness, payload)
      return @caller.with(harness:, session_id: payload['session_id'] || @caller.session_id) if harness == 'claude'

      session = payload[harness == 'cursor' ? 'conversation_id' : 'session_id']
      @caller.with(harness:, session_id: session, pid: nil, claude_socket: nil)
    end

    def pending(name)
      { UNREAD_MARK => @store.unread(name), UNANSWERED_MARK => unanswered_requests(name) }
        .to_h { |mark, messages| [mark, messages.reject { @store.marked?(name, it.id, mark) }] }
    end

    def reminder(name, pending)
      return nil if pending.values.all?(&:empty?)

      reason(name, *pending.values_at(UNREAD_MARK, UNANSWERED_MARK))
    end

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
