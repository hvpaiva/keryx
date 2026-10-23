# frozen_string_literal: true

require_relative 'bell'
require_relative 'error'
require_relative 'forwarder'
require_relative 'identity'
require_relative 'message'
require_relative 'ulid'

module Keryx
  class Postman
    Posted = Data.define(:message, :bell, :forward)

    def initialize(store:, bell:, forwarder:, host:, clock:, person:, measure: ->(_name) {})
      @store = store
      @bell = bell
      @forwarder = forwarder
      @host = host
      @clock = clock
      @person = person
      @measure = measure
    end

    def self.check_body(body)
      text = String.new(body.to_s, encoding: Encoding::UTF_8)
      raise Error, 'the message is not valid UTF-8' unless text.valid_encoding?
      raise UsageError, 'the message is empty' if text.strip.empty?
      return text if text.bytesize <= Message::MAX_BODY_BYTES

      raise Error, "the message is #{text.bytesize} bytes and the limit is #{Message::MAX_BODY_BYTES}; " \
                   'write long content to a file and send its path'
    end

    # A claim is asked in the same hold of the occupants lock as the write for the id the message goes under, and one
    # that gives none leaves the message unwritten; the bell and the forward come after the hold.
    def post(sender:, recipient:, kind:, body:, due_at: nil, reply_to: nil, id: nil, ring: true, claim: nil)
      check_recipient(recipient)
      body = Postman.check_body(body)
      context = @measure.call(sender)
      letter = ->(given) { compose(sender, recipient, kind:, body:, due_at:, reply_to:, id: given, context:) }
      return post_away(recipient.host, letter, id, claim) unless recipient.local?(@host)

      @store.create_address(recipient.name, role: Identity::HUMAN_ROLE) unless @store.address?(recipient.name)
      message, stored = write(letter, id, claim) { @store.deliver(recipient.name, it) }
      return unless message

      # A message posted again under its id is already in the mailbox, and the courier rings again for its bell.
      bell = announce(recipient.name, message) if ring && stored == :delivered && recipient.name != sender
      Posted.new(message:, bell:, forward: nil)
    end

    # The withdrawal goes where the request is, since the request may name this machine by a name it no longer has.
    def withdraw(request, holder:, body:)
      now = @clock.call
      message = Message.new(id: Ulid.generate(now), kind: 'withdrawal', from: request.from, to: request.to,
                            thread: request.thread, in_reply_to: request.id, created_at: now, due_at: nil,
                            body: Postman.check_body(body), context: @measure.call(request.from.split('@').first))
      return forward(message, request.to.split('@').last) unless holder

      @store.deliver(holder, message)
      bell = announce(holder, message) unless holder == request.from.split('@').first
      Posted.new(message:, bell:, forward: nil)
    end

    private

    def announce(name, message)
      @bell.ring(name, [message])
    rescue StandardError => e
      Bell::Result.new(status: Bell::FAILED, channel: nil, detail: e.message, at: @clock.call)
    end

    # The message and what writing it gave, or nil when the claim gave no id.
    def write(letter, id, claim)
      return letter.call(id).then { [it, yield(it)] } unless claim

      @store.with_occupants_lock do
        claimed = claim.call
        letter.call(claimed).then { [it, yield(it)] } if claimed
      end
    end

    def post_away(host, letter, id, claim)
      message, = write(letter, id, claim) { @store.outbox.queue(host, it) }
      forwarded(message, host) if message
    end

    def forward(message, host)
      @store.outbox.queue(host, message)
      forwarded(message, host)
    end

    def forwarded(message, host)
      result = @forwarder.forward(host)[message.id] || settled(host, message.id)
      return Posted.new(message:, bell: nil, forward: result) unless result.status == Forwarder::REFUSED

      @store.outbox.discard(host, message.id)
      raise Error, "#{host} refused the message; #{result.detail}"
    end

    def settled(host, id)
      @forwarder.settled(host, id) or raise Error, "#{id} left the outbox for #{host} without a receipt"
    end

    def compose(sender, recipient, kind:, body:, due_at:, reply_to:, id:, context:)
      now = @clock.call
      id ||= Ulid.generate(now)
      Message.new(id:, kind:, from: "#{sender}@#{@host}", to: recipient.to_s, thread: reply_to&.thread || id,
                  in_reply_to: reply_to&.id, created_at: now, due_at:, body:, context:)
    end

    def check_recipient(recipient)
      return unless recipient.local?(@host)
      return if @store.address?(recipient.name) || recipient.name == @person

      raise Error, "no address #{recipient}; 'keryx who' lists the addresses on #{@host}"
    end
  end
end
