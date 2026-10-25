# frozen_string_literal: true

require 'json'
require_relative 'address'
require_relative 'bell'
require_relative 'error'
require_relative 'identity'
require_relative 'message'
require_relative 'postman'
require_relative 'retirement'
require_relative 'store'
require_relative 'ulid'

module Keryx
  class Receiver
    FRAME_LIMIT = (6 * Message::MAX_BODY_BYTES) + 4096
    CLAIMED_ID = /"id":"(?<id>[0-9A-HJKMNP-TV-Z]{26})"/
    FAILED = 'failed'
    BEHIND = 'it waits for %<id>s, written before it in its thread'

    def initialize(store:, bell:, host:, person:, live: ->(_name) {})
      @store = store
      @bell = bell
      @host = host
      @person = person
      @live = live
    end

    def receive_all(input, &)
      @oversized = nil
      stalled = {}
      input.each_line(FRAME_LIMIT) do |chunk|
        next skip(chunk, &) if @oversized || truncated?(chunk)

        yield receive(chunk, stalled) unless chunk.strip.empty?
      end
      yield too_large(@oversized[:id]) if @oversized
    end

    # The forwarder sends a batch in id order, which is the order its messages were written in to the millisecond.
    # Once a message of a thread fails, each later one of that thread fails too without being written, so none
    # overtakes it and the sender sends them all again in that order. STALLED holds, by thread, the first that failed.
    def receive(line, stalled = {})
      message = Message.from_json(line)
      earlier = stalled[message.thread]
      return receipt(message.id, FAILED, detail: format(BEHIND, id: earlier)) if earlier

      take(message).tap { stalled[message.thread] = message.id if it['status'] == FAILED }
    rescue StandardError => e
      failure(claimed_id(line), e)
    end

    private

    def take(message)
      to = Address.parse(message.to)
      refusal = refusal(message, to)
      return receipt(message.id, 'refused', detail: refusal) if refusal

      status = deliver(to, message)
      receipt(message.id, status.to_s, bell: (ring(to.name, message) if status == :delivered))
    rescue StandardError => e
      failure(message.id, e)
    end

    # keryx's own errors refuse the message, but a lock another command keeps fails it, as any other error does, so the
    # sender sends it again.
    def failure(id, error)
      refused = error.is_a?(Error) && !error.is_a?(Store::Busy)
      receipt(id, refused ? 'refused' : FAILED, detail: error.message)
    end

    def truncated?(chunk) = chunk.bytesize >= FRAME_LIMIT && !chunk.end_with?("\n")

    def skip(chunk)
      @oversized ||= { id: chunk[CLAIMED_ID, :id] }
      return unless chunk.end_with?("\n")

      yield too_large(@oversized[:id])
      @oversized = nil
    end

    def too_large(id) = receipt(id, 'refused', detail: "the message is larger than #{FRAME_LIMIT} bytes")

    # Mail to a session address is checked again in the hold that writes it. A lock another command keeps there is no
    # refusal, so the sender keeps the message and sends it again.
    def deliver(to, message)
      @store.create_address(to.key, role: Identity::HUMAN_ROLE) unless @store.address?(to.key)
      return @store.deliver(to.key, message) unless bound?(message, to)

      Postman.bound(@store, to, @live) { @store.deliver(to.key, message) }
    end

    # Mail to a session address waits for its session, but two kinds are written with neither the check nor the lock,
    # and once the session left, the holder of the address reads them: the withdrawal of a request the mailbox holds,
    # as Postman#withdraw writes one here, so its sender stops waiting, and a notice from keryx on the sending machine,
    # which can tell only its own sessions apart. The sender's address is the one the message gives, since keryx
    # trusts SSH between machines, and such a message could reach the holder at the stable address all the same.
    def bound?(message, to) = !to.session.nil? && !notice?(message) && !withdraws_held?(message, to)

    def notice?(message) = Address.parse(message.from).key == Identity::SYSTEM

    def withdraws_held?(message, to)
      message.withdrawal? && @store.stored(to.key).any? { message.withdraws?(it.message) }
    end

    def ring(name, message)
      @bell.ring(name, [message]).record
    rescue StandardError => e
      { 'status' => Bell::FAILED, 'detail' => e.message }
    end

    def refusal(message, to)
      from = Address.parse(message.from)
      return "#{message.to} is not on #{@host}" unless to.local?(@host)
      return "#{message.from} is on #{@host} and cannot arrive from another machine" if from.local?(@host)
      return retired(message, to) if @store.retired?(to.key)
      return "no address #{message.to}" unless @store.address?(to.key) || to.key == @person

      Postman.session_left(@store, to, @live) if bound?(message, to)
    end

    # A withdrawal still settles a request that arrived as the address was retired, so its sender stops waiting.
    def retired(message, to)
      return if withdraws_held?(message, to)

      format(Retirement::RETIRED, to)
    end

    def receipt(id, status, detail: nil, bell: nil)
      { 'id' => id, 'status' => status, 'detail' => detail, 'bell' => bell }.compact
    end

    def claimed_id(line)
      data = JSON.parse(line)
      data['id'] if data.is_a?(Hash) && Ulid.valid?(data['id'])
    rescue JSON::ParserError
      nil
    end
  end
end
