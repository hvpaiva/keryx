# frozen_string_literal: true

require 'time'

module Keryx
  class Forwarder
    Result = Data.define(:status, :detail, :bell)

    FORWARDED = 'forwarded'
    QUEUED = 'queued'
    REFUSED = 'refused'
    FAILED = 'failed'
    ARRIVED = %w[delivered duplicate].freeze

    def initialize(store:, remote:, clock:)
      @store = store
      @remote = remote
      @clock = clock
    end

    # A message that kept its outcome but not its move, since the attempt stopped between the two, is not sent again.
    def forward(host)
      queued = @store.outbox.queued(host).map { [it, settled(host, it.id)] }
      waiting = queued.reject(&:last).map(&:first)
      answer = @remote.deliver(host, waiting) unless waiting.empty?
      queued.to_h do |message, outcome|
        [message.id, outcome ? move(host, message.id, outcome) : settle(host, message, answer)]
      end
    end

    def settled(host, id)
      outcome = @store.outbox.outcome(host, id) or return nil
      Result.new(status: outcome['status'], detail: outcome['detail'], bell: outcome['bell'])
    end

    private

    def settle(host, message, answer)
      receipt = answer.receipts[message.id]
      if receipt && ARRIVED.include?(receipt['status'])
        finish(host, message, FORWARDED, nil, bell: receipt['bell'])
      elsif receipt && receipt['status'] == REFUSED
        finish(host, message, REFUSED, receipt['detail'].to_s)
      else
        wait(host, message, waiting_reason(host, message, receipt, answer))
      end
    end

    # The outcome comes first, so a sender that finds the message gone from new/ can read how it settled.
    def finish(host, message, status, detail, bell: nil)
      @store.outbox.write_outcome(host, message.id, data(status, detail, bell:))
      settled(host, message.id)&.then { move(host, message.id, it) }
    end

    def move(host, id, outcome)
      @store.outbox.settle(host, id, outcome.status.to_sym)
      outcome
    end

    def wait(host, message, reason)
      @store.outbox.write_receipt(host, message.id, data(QUEUED, reason, attempts: attempts(host, message) + 1))
      settled(host, message.id) || Result.new(status: QUEUED, detail: reason, bell: nil)
    end

    def waiting_reason(host, message, receipt, answer)
      return "#{host} could not store it; #{receipt['detail']}" if receipt && receipt['status'] == FAILED

      answer.error || "#{host} sent no receipt for #{message.id}"
    end

    def attempts(host, message) = @store.outbox.receipt(host, message.id)&.fetch('attempts', 0).to_i

    def data(status, detail, bell: nil, attempts: nil)
      { 'status' => status, 'detail' => detail, 'bell' => bell, 'attempts' => attempts,
        'at' => @clock.call.utc.iso8601 }.compact
    end
  end
end
