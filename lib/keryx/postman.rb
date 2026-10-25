# frozen_string_literal: true

require_relative 'address'
require_relative 'bell'
require_relative 'error'
require_relative 'forwarder'
require_relative 'identity'
require_relative 'message'
require_relative 'retirement'
require_relative 'ulid'

module Keryx
  class Postman
    Posted = Data.define(:message, :bell, :forward)
    SESSION_LEFT = 'mail to %<address>s is refused: its session left; write to %<stable>s'

    def initialize(store:, bell:, forwarder:, host:, clock:, person:, measure: ->(_name) {}, live: ->(_name) {})
      @store = store
      @bell = bell
      @forwarder = forwarder
      @host = host
      @clock = clock
      # The name of the person at this terminal, or its names, which mail may go to before the person has an address.
      @people = Array(person)
      @measure = measure
      @live = live
    end

    def self.check_body(body)
      text = String.new(body.to_s, encoding: Encoding::UTF_8)
      raise Error, 'the message is not valid UTF-8' unless text.valid_encoding?
      raise UsageError, 'the message is empty' if text.strip.empty?
      return text if text.bytesize <= Message::MAX_BODY_BYTES

      raise Error, "the message is #{text.bytesize} bytes and the limit is #{Message::MAX_BODY_BYTES}; " \
                   'write long content to a file and send its path'
    end

    # A session address takes mail only while its session is bound to the address and runs.
    def self.session_left(store, address, live)
      return if address.session.nil? || (store.occupant(address.name) && live.call(address.name))

      format(SESSION_LEFT, address:, stable: address.stable)
    end

    # leave and join end or move a binding in a hold of the occupants lock, so mail to a session address is written in
    # the hold that finds its session still bound, and none of them comes between the check and the write.
    def self.bound(store, address, live)
      store.with_occupants_lock do
        left = session_left(store, address, live)
        raise Error, left if left

        yield
      end
    end

    # A claim is asked in the same hold of the occupants lock as the write for the id the message goes under, and one
    # that gives none leaves the message unwritten; a session address here is checked again in that hold. The bell and
    # the forward come after the hold.
    def post(sender:, recipient:, kind:, body:, due_at: nil, reply_to: nil, id: nil, ring: true, claim: nil)
      check_recipient(recipient)
      body = Postman.check_body(body)
      context = @measure.call(sender)
      letter = ->(given) { compose(sender, recipient, kind:, body:, due_at:, reply_to:, id: given, context:) }
      return post_away(recipient.host, letter, id, claim, reply_to) unless recipient.local?(@host)

      name = recipient.key
      @store.create_address(name, role: Identity::HUMAN_ROLE) unless @store.address?(name)
      message, stored = held(claim, recipient) { write(letter, id, claim) { @store.deliver(name, it) } }
      return unless message

      # A message posted again under its id is already in the mailbox, and the courier rings again for its bell.
      bell = announce(recipient.name, message) if ring && stored == :delivered && recipient.name != sender
      Posted.new(message:, bell:, forward: nil)
    end

    # The withdrawal goes where the request is, since the request may name this machine by a name it no longer has.
    def withdraw(request, holder:, body:)
      from, to = [request.from, request.to].map { Address.parse(it) }
      letter = withdrawal(request, Postman.check_body(body), @measure.call(from.name))
      return in_thread(to.host, request.thread, letter) unless holder

      message = letter.call(nil)
      @store.deliver(holder, message)
      bell = announce(to.name, message) unless holder == from.key
      Posted.new(message:, bell:, forward: nil)
    end

    private

    def announce(name, message)
      @bell.ring(name, [message])
    rescue StandardError => e
      Bell::Result.new(status: Bell::FAILED, channel: nil, detail: e.message, at: @clock.call)
    end

    def held(claim, recipient = nil, &)
      return Postman.bound(@store, recipient, @live, &) if recipient&.session
      return yield unless claim

      @store.with_occupants_lock(&)
    end

    # The message and what writing it gave, or nil when the claim gave no id.
    def write(letter, id, claim)
      return letter.call(id).then { [it, yield(it)] } unless claim

      claimed = claim.call
      letter.call(claimed).then { [it, yield(it)] } if claimed
    end

    # The withdrawal of REQUEST, under the id it is given or else one drawn from the clock.
    def withdrawal(request, body, context)
      now = @clock.call
      lambda do |id|
        Message.new(id: id || Ulid.generate(now), kind: 'withdrawal', from: request.from, to: request.to,
                    thread: request.thread, in_reply_to: request.id, created_at: now, due_at: nil, body:, context:)
      end
    end

    def post_away(host, letter, id, claim, reply_to)
      return in_thread(host, reply_to.thread, letter) if reply_to && !id && !claim

      message, = held(claim) { write(letter, id, claim) { @store.outbox.queue(host, it) } }
      forwarded(message, host) if message
    end

    # A message of a thread for another machine takes an id after the last one of its thread still waiting there, so
    # the forwarder sends them in the order they were written, whatever the clock says.
    def in_thread(host, thread, letter)
      message = @store.outbox.queue_in_thread(host, thread) do |last|
        letter.call([Ulid.generate(@clock.call), Ulid.after(last)].compact.max)
      end
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
      Message.new(id:, kind:, from: from(sender, reply_to), to: recipient.to_s, thread: reply_to&.thread || id,
                  in_reply_to: reply_to&.id, created_at: now, due_at:, body:, context:)
    end

    # In a thread, any incarnation of the address a message went to writes as the address it went to, so a reply or a
    # message from a session that join --force displaced still answers or takes the request.
    def from(sender, reply_to)
      own = Address.from_name(sender, host: @host)
      to = reply_to && Address.parse(reply_to.to)
      (to && to.host == own.host && to.key == own.key ? to : own).to_s
    end

    def check_recipient(recipient)
      return unless recipient.local?(@host)
      raise Error, format(Retirement::RETIRED, recipient) if @store.retired?(recipient.key)
      raise Error, "no address #{recipient}; 'keryx who' lists the addresses on #{@host}" unless
        @store.address?(recipient.key) || @people.include?(recipient.key)

      left = Postman.session_left(@store, recipient, @live)
      raise Error, left if left
    end
  end
end
