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

    def forward(host)
      messages = @store.outbox.queued(host)
      return {} if messages.empty?

      answer = @remote.deliver(host, messages)
      messages.to_h { [it.id, settle(host, it, answer)] }
    end

    def settled(host, id)
      receipt = @store.outbox.receipt(host, id) or return nil
      Result.new(status: receipt['status'], detail: receipt['detail'], bell: receipt['bell'])
    end

    private

    def settle(host, message, answer)
      receipt = answer.receipts[message.id]
      if receipt && ARRIVED.include?(receipt['status'])
        finish(host, message, :forwarded, record(host, message, FORWARDED, nil, bell: receipt['bell']))
      elsif receipt && receipt['status'] == REFUSED
        finish(host, message, :refused, record(host, message, REFUSED, receipt['detail'].to_s))
      else
        record(host, message, QUEUED, waiting_reason(host, message, receipt, answer),
               attempts: attempts(host, message) + 1)
      end
    end

    # The receipt comes first, so a sender that finds the message gone from new/ can read how it settled.
    def finish(host, message, state, result)
      @store.outbox.settle(host, message.id, state)
      result
    end

    def waiting_reason(host, message, receipt, answer)
      return "#{host} could not store it; #{receipt['detail']}" if receipt && receipt['status'] == FAILED

      answer.error || "#{host} sent no receipt for #{message.id}"
    end

    def attempts(host, message) = @store.outbox.receipt(host, message.id)&.fetch('attempts', 0).to_i

    def record(host, message, status, detail, bell: nil, attempts: nil)
      data = { 'status' => status, 'detail' => detail, 'bell' => bell, 'attempts' => attempts,
               'at' => @clock.call.utc.iso8601 }
      @store.outbox.write_receipt(host, message.id, data.compact)
      Result.new(status:, detail:, bell:)
    end
  end
end
