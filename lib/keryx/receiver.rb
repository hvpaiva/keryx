# frozen_string_literal: true

require 'json'
require_relative 'address'
require_relative 'bell'
require_relative 'check'
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
    # The checks of a batch end within it, so the one ssh run that brings the batch ends before Remote::TIMEOUT, 60 s:
    # 10 s to connect, 40 s of checks and 10 s for the rest. A checker's longest timeout and its kill grace, 31 s, fit
    # in it, so every batch checks at least one message and the queue moves.
    CHECK_BUDGET = 40
    OUT_OF_TIME = 'the check on %<host>s ran out of time in this batch'

    def initialize(store:, bell:, host:, person:, check:, live: ->(_name) {},
                   monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, budget: CHECK_BUDGET)
      @store = store
      @bell = bell
      @host = host
      @person = person
      @check = check
      @live = live
      @monotonic = monotonic
      @budget = budget
    end

    def receive_all(input, &)
      @oversized = nil
      @started = @monotonic.call
      @out_of_time = false
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

    # A message the mailbox holds already is a resend of one written before, so it is answered as the duplicate it is,
    # with no check, and a resent batch moves past what arrived.
    def take(message)
      to = Address.parse(message.to)
      refusal = refusal(message, to)
      return receipt(message.id, 'refused', detail: refusal) if refusal
      return receipt(message.id, 'duplicate') if @store.stored?(to.key, message.id)

      checked = screen(message)
      return checked if checked

      status = deliver(to, message)
      receipt(message.id, status.to_s, bell: (ring(to.name, message) if status == :delivered))
    rescue StandardError => e
      failure(message.id, e)
    end

    # The receipt of a message the check keeps out, or nil when it may be written. Once a check could pass the batch's
    # budget, every later message that needs one fails, so its thread stalls and the sender sends it again. A check that
    # fails refuses rather than fails, so a broken checker shows once instead of being sent again on every pass.
    def screen(message)
      timeout = @check.timeout_for(message) or return
      @out_of_time ||= @monotonic.call - (@started ||= @monotonic.call) + timeout + Checker::KILL_GRACE > @budget
      return receipt(message.id, FAILED, detail: format(OUT_OF_TIME, host: @host)) if @out_of_time

      reason = @check.refusal(message, event: Check::RECEIVE, command: nil)
      receipt(message.id, 'refused', detail: reason) if reason
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
      teamless = message.teamless
      return format(Address::TEAMLESS, teamless) if teamless
      return "#{message.to} is not on #{@host}" unless to.local?(@host)
      return "#{message.from} is on #{@host} and cannot arrive from another machine" if from.local?(@host)
      return retired(message, to) if @store.retired?(to.key)
      return "no address #{message.to}" unless @store.address?(to.key) || to.key == @person

      session_left(message, to)
    end

    # Only the mail that bound? holds for its session is refused once that session left.
    def session_left(message, to)
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
