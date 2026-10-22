# frozen_string_literal: true

require_relative 'error'
require_relative 'forwarder'
require_relative 'identity'
require_relative 'message'
require_relative 'ulid'

module Keryx
  class Postman
    Posted = Data.define(:message, :bell, :forward)

    def initialize(store:, bell:, forwarder:, host:, clock:, person:)
      @store = store
      @bell = bell
      @forwarder = forwarder
      @host = host
      @clock = clock
      @person = person
    end

    def post(sender:, recipient:, kind:, body:, due_at: nil, reply_to: nil, id: nil)
      check_recipient(recipient)
      check_body(body)
      message = compose(sender, recipient, kind:, body:, due_at:, reply_to:, id:)
      return forward(message, recipient.host) unless recipient.local?(@host)

      @store.create_address(recipient.name, role: Identity::HUMAN_ROLE) unless @store.address?(recipient.name)
      @store.deliver(recipient.name, message)
      bell = @bell.ring(recipient.name, [message]) unless recipient.name == sender
      Posted.new(message:, bell:, forward: nil)
    end

    private

    def forward(message, host)
      @store.outbox.queue(host, message)
      result = @forwarder.forward(host)[message.id] || settled(host, message.id)
      return Posted.new(message:, bell: nil, forward: result) unless result.status == Forwarder::REFUSED

      @store.outbox.discard(host, message.id)
      raise Error, "#{host} refused the message; #{result.detail}"
    end

    def settled(host, id)
      @forwarder.settled(host, id) or raise Error, "#{id} left the outbox for #{host} without a receipt"
    end

    def compose(sender, recipient, kind:, body:, due_at:, reply_to:, id:)
      now = @clock.call
      id ||= Ulid.generate(now)
      Message.new(id:, kind:, from: "#{sender}@#{@host}", to: recipient.to_s, thread: reply_to&.thread || id,
                  in_reply_to: reply_to&.id, created_at: now, due_at:, body:)
    end

    def check_recipient(recipient)
      return unless recipient.local?(@host)
      return if @store.address?(recipient.name) || recipient.name == @person

      raise Error, "no address #{recipient}; 'keryx who' lists the addresses on #{@host}"
    end

    def check_body(body)
      raise UsageError, 'the message is empty' if body.to_s.strip.empty?
      raise Error, 'the message is not valid UTF-8' unless body.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      return if body.bytesize <= Message::MAX_BODY_BYTES

      raise Error, "the message is #{body.bytesize} bytes and the limit is #{Message::MAX_BODY_BYTES}; " \
                   'write long content to a file and send its path'
    end
  end
end
