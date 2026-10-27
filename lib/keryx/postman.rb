# frozen_string_literal: true

require_relative 'address'
require_relative 'bell'
require_relative 'check'
require_relative 'error'
require_relative 'forwarder'
require_relative 'identity'
require_relative 'message'
require_relative 'retirement'
require_relative 'ulid'

module Keryx
  class Postman
    Posted = Data.define(:message, :bell, :forward)
    # Mail to an address this machine does not have and that is not the person's, which the first message makes.
    class NoAddress < Error; end
    SESSION_LEFT = 'mail to %<address>s is refused: its session left; write to %<stable>s'

    def initialize(store:, bell:, forwarder:, host:, clock:, person:, check:, measure: ->(_name) {},
                   live: ->(_name) {})
      @store = store
      @bell = bell
      @forwarder = forwarder
      @host = host
      @clock = clock
      @person = person
      @check = check
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

    # The message is composed and checked before any lock is taken, so a slow checker holds none, and what is written
    # is the message checked. A claim is asked in the same hold of the occupants lock as the write for the id the
    # message goes under, and one that gives none leaves the message unwritten; a session address here is checked
    # again in that hold. The bell and the forward come after the hold. COMMAND names the command for the check.
    def post(sender:, recipient:, kind:, body:, due_at: nil, reply_to: nil, id: nil, ring: true, claim: nil,
             command: nil)
      check_recipient(recipient)
      draft = compose(sender, recipient, kind:, body: Postman.check_body(body), due_at:, reply_to:, id:,
                                         context: @measure.call(sender))
      screen(draft, command, claim)
      return post_away(recipient.host, draft, id, claim, reply_to) unless recipient.local?(@host)

      name = recipient.key
      @store.create_address(name, role: Identity::HUMAN_ROLE) unless @store.address?(name)
      message, stored = held(claim, recipient) { write(draft, claim) { @store.deliver(name, it) } }
      return unless message

      # A message posted again under its id is already in the mailbox, and the courier rings again for its bell.
      bell = announce(recipient.name, message) if ring && stored == :delivered && recipient.name != sender
      Posted.new(message:, bell:, forward: nil)
    end

    # The withdrawal goes where the request is, since the request may name this machine by a name it no longer has.
    def withdraw(request, holder:, body:)
      teamless = request.teamless
      raise Error, format(Address::TEAMLESS, teamless) if teamless

      from, to = [request.from, request.to].map { Address.parse(it) }
      message = withdrawal(request, Postman.check_body(body), @measure.call(from.name))
      screen(message, 'withdraw', nil)
      return in_thread(to.host, request.thread, message) unless holder

      @store.deliver(holder, message)
      bell = announce(to.name, message) unless holder == from.key
      Posted.new(message:, bell:, forward: nil)
    end

    # MESSAGE under ID, where one that opens its own thread still names the thread after itself.
    def self.renamed(message, id)
      return message if id.nil? || id == message.id

      message.with(id:, thread: message.thread == message.id ? id : message.thread)
    end

    private

    # Only an exempt sender's post may claim, since a claim holds the occupants lock and a check there would hold it
    # for the checker's whole timeout.
    def screen(message, command, claim)
      raise ArgumentError, 'only a sender the check exempts posts with a claim' if claim && !@check.exempt?(message)

      reason = @check.refusal(message, event: Check::SEND, command:)
      raise Error, reason if reason
    end

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
    def write(draft, claim)
      return [draft, yield(draft)] unless claim

      claimed = claim.call
      Postman.renamed(draft, claimed).then { [it, yield(it)] } if claimed
    end

    def withdrawal(request, body, context)
      now = @clock.call
      Message.new(id: Ulid.generate(now), kind: 'withdrawal', from: request.from, to: request.to,
                  thread: request.thread, in_reply_to: request.id, created_at: now, due_at: nil, body:, context:)
    end

    def post_away(host, draft, id, claim, reply_to)
      return in_thread(host, reply_to.thread, draft) if reply_to && !id && !claim

      message, = held(claim) { write(draft, claim) { @store.outbox.queue(host, it) } }
      forwarded(message, host) if message
    end

    # A message of a thread for another machine takes an id after the last one of its thread still waiting there, so
    # the forwarder sends them in the order they were written, whatever the clock says. Only then does the id differ
    # from the one checked, and it is the only field that does.
    def in_thread(host, thread, draft)
      message = @store.outbox.queue_in_thread(host, thread) do |last|
        Postman.renamed(draft, [draft.id, Ulid.after(last)].compact.max)
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
      raise Error, format(Address::TEAMLESS, recipient) if recipient.flat?
      return unless recipient.local?(@host)
      raise Error, format(Retirement::RETIRED, recipient) if @store.retired?(recipient.key)
      raise NoAddress, "no address #{recipient}; 'keryx who' lists the addresses on #{@host}" unless
        @store.address?(recipient.key) || recipient.key == @person

      left = Postman.session_left(@store, recipient, @live)
      raise Error, left if left
    end
  end
end
