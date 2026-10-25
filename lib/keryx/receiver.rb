# frozen_string_literal: true

require 'json'
require_relative 'address'
require_relative 'bell'
require_relative 'error'
require_relative 'identity'
require_relative 'message'
require_relative 'postman'
require_relative 'retirement'
require_relative 'roster'
require_relative 'store'
require_relative 'ulid'

module Keryx
  class Receiver
    FRAME_LIMIT = (6 * Message::MAX_BODY_BYTES) + 4096
    CLAIMED_ID = /"id":"(?<id>[0-9A-HJKMNP-TV-Z]{26})"/

    def initialize(store:, bell:, host:, person:, live: ->(_name) {})
      @store = store
      @bell = bell
      @host = host
      @person = person
      @live = live
    end

    def receive_all(input, &)
      @oversized = nil
      input.each_line(FRAME_LIMIT) do |chunk|
        next skip(chunk, &) if @oversized || truncated?(chunk)

        yield receive(chunk) unless chunk.strip.empty?
      end
      yield too_large(@oversized[:id]) if @oversized
    end

    def receive(line)
      message = Message.from_json(line)
      to = Address.parse(message.to)
      refusal = refusal(message, to)
      return receipt(message.id, 'refused', detail: refusal) if refusal

      status = deliver(to, message)
      receipt(message.id, status.to_s, bell: (ring(to.name, message) if status == :delivered))
    rescue Error => e
      receipt(claimed_id(line), e.is_a?(Store::Busy) ? 'failed' : 'refused', detail: e.message)
    rescue StandardError => e
      receipt(claimed_id(line), 'failed', detail: e.message)
    end

    private

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
      return @store.deliver(to.key, message) unless to.session

      Postman.bound(@store, to, @live) { @store.deliver(to.key, message) }
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

      Postman.session_left(@store, to, @live) || flat(message, from, to)
    end

    # An address from before team names only finishes its threads, whichever format carried the message, so what
    # reaches it or comes from it answers, takes or withdraws a request this store holds, and never starts one.
    def flat(message, from, to)
      address = [from, to].find(&:flat?)
      return unless address && !finishes?(message, from, to)

      format(Postman::FLAT_RECIPIENT, address:)
    end

    # A message the mailbox already holds is a duplicate, whatever became of its thread, so a sender that lost the
    # receipt and sends it again stops. A new one finishes only a request still open. Every message between an address
    # here and one elsewhere is kept in the mailbox here or in the outbox to that machine, so the request and whatever
    # answered or withdrew it are looked for there alone.
    def finishes?(message, from, to)
      mail = @store.stored(to.key).map(&:message)
      return true if mail.any? { it.id == message.id }

      thread = mail + @store.outbox.outgoing(from.host).reject { it.state == :refused }.map(&:message)
      request = thread.find { it.id == message.in_reply_to } or return false
      %i[answers? takes? withdraws?].any? { message.public_send(it, request) } &&
        thread.none? { Roster.settles?(it, request) }
    end

    # A withdrawal still settles a request that arrived as the address was retired, so its sender stops waiting.
    def retired(message, to)
      return if message.withdrawal? && @store.stored(to.key).any? { message.withdraws?(it.message) }

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
