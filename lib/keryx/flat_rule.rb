# frozen_string_literal: true

require_relative 'address'
require_relative 'roster'

module Keryx
  # An address from before team names only finishes its threads, on this machine as from another and whichever format
  # carried the message: what reaches it or comes from it answers, takes or withdraws a request still open, and never
  # starts one.
  module FlatRule
    RECIPIENT = '%<address>s is an address from before team names: it takes only replies, withdrawals and messages ' \
                'in its open threads'
    SENDER = '%<address>s is an address from before team names: it sends only replies, withdrawals and messages in ' \
             'its open threads'
    OVER = 'request %<request>s is over, and %<rule>s'

    module_function

    # Why MESSAGE may not go, or nil when it may. A message already where it goes is no new one, whatever became of its
    # thread, so a sender that lost the receipt and sends it again stops.
    def refusal(store, message, host:)
      from, to = [message.from, message.to].map { Address.parse(it) }
      return unless from.flat? || to.flat?

      origin, destination = [from, to].map { held(store, it, host) }
      return if destination.any? { it.id == message.id }

      rule = to.flat? ? format(RECIPIENT, address: to) : format(SENDER, address: from)
      thread = origin + destination
      request = finished(message, thread) or return rule
      format(OVER, request: request.id, rule:) if thread.any? { Roster.settles?(it, request) }
    end

    # Every message between an address here and one elsewhere is kept in the mailbox here or in the outbox to that
    # machine, and one between two addresses here in their mailboxes, so a thread is looked for there alone.
    def held(store, address, host)
      return store.stored(address.key).map(&:message) if address.local?(host)

      store.outbox.outgoing(address.host).reject { it.state == :refused }.map(&:message)
    end

    def finished(message, thread)
      request = thread.find { it.id == message.in_reply_to } or return
      request if %i[answers? takes? withdraws?].any? { message.public_send(it, request) }
    end
    private_class_method :held, :finished
  end
end
