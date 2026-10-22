# frozen_string_literal: true

require_relative 'error'
require_relative 'message'
require_relative 'ulid'

module Keryx
  class Postman
    Posted = Data.define(:message, :bell)

    def initialize(store:, bell:, host:, clock:)
      @store = store
      @bell = bell
      @host = host
      @clock = clock
    end

    def post(sender:, recipient:, kind:, body:, due_at: nil, reply_to: nil)
      check_recipient(recipient)
      check_body(body)
      message = compose(sender, recipient, kind:, body:, due_at:, reply_to:)
      @store.deliver(recipient.name, message)
      bell = @bell.ring(recipient.name, [message]) unless recipient.name == sender
      Posted.new(message:, bell:)
    end

    private

    def compose(sender, recipient, kind:, body:, due_at:, reply_to:)
      now = @clock.call
      id = Ulid.generate(now)
      Message.new(id:, kind:, from: "#{sender}@#{@host}", to: recipient.to_s, thread: reply_to&.thread || id,
                  in_reply_to: reply_to&.id, created_at: now, due_at:, body:)
    end

    def check_recipient(recipient)
      unless recipient.local?(@host)
        raise Error, "#{recipient} is on another machine; this version of keryx delivers on #{@host} only"
      end
      return if @store.address?(recipient.name)

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
