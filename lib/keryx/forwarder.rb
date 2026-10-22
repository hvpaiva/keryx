# frozen_string_literal: true

require 'time'

module Keryx
  class Forwarder
    Result = Data.define(:status, :detail, :bell)

    FORWARDED = 'forwarded'
    QUEUED = 'queued'
    REFUSED = 'refused'
    ARRIVED = %w[delivered duplicate].freeze

    def initialize(store:, remote:, clock:)
      @store = store
      @remote = remote
      @clock = clock
    end

    def forward(host)
      messages = @store.queued(host)
      return {} if messages.empty?

      answer = @remote.deliver(host, messages)
      messages.to_h { [it.id, settle(host, it, answer)] }
    end

    private

    def settle(host, message, answer)
      receipt = answer.receipts[message.id]
      if receipt && ARRIVED.include?(receipt['status'])
        @store.settle(host, message.id, :forwarded)
        record(host, message, FORWARDED, nil, bell: receipt['bell'])
      elsif receipt && receipt['status'] == REFUSED
        @store.settle(host, message.id, :refused)
        record(host, message, REFUSED, receipt['detail'].to_s)
      else
        record(host, message, QUEUED, answer.error || "#{host} sent no receipt for #{message.id}",
               attempts: attempts(host, message) + 1)
      end
    end

    def attempts(host, message) = @store.forward_receipt(host, message.id)&.fetch('attempts', 0).to_i

    def record(host, message, status, detail, bell: nil, attempts: nil)
      data = { 'status' => status, 'detail' => detail, 'bell' => bell, 'attempts' => attempts,
               'at' => @clock.call.utc.iso8601 }
      @store.write_forward_receipt(host, message.id, data.compact)
      Result.new(status:, detail:, bell:)
    end
  end
end
