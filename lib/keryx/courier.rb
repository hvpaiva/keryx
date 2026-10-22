# frozen_string_literal: true

require_relative 'address'
require_relative 'bell'
require_relative 'error'
require_relative 'ulid'

module Keryx
  class Courier
    Round = Data.define(:forwarded, :rung, :overdue, :errors)
    NAME = 'keryx'
    OVERDUE_MARK = 'overdue'
    UNREACHABLE = %w[none gone].freeze

    def initialize(store:, forwarder:, bell:, roster:, postman:, host:, clock:)
      @store = store
      @forwarder = forwarder
      @bell = bell
      @roster = roster
      @postman = postman
      @host = host
      @clock = clock
    end

    def round
      roster = @roster.call
      @errors = []
      Round.new(forwarded: forward, rung: ring_again(roster), overdue: remind_overdue(roster), errors: @errors)
    end

    private

    def forward
      @store.outbox.hosts.to_h { [it, @forwarder.forward(it)] }.reject { |_host, results| results.empty? }
    end

    def ring_again(roster)
      roster.entries.filter_map do |entry|
        next if UNREACHABLE.include?(entry.session)

        waiting = @store.unread(entry.name).reject { rung?(entry.name, it) }
        [entry.name, @bell.ring(entry.name, waiting)] unless waiting.empty?
      end.to_h
    end

    def rung?(name, message)
      message.from == message.to || @store.receipt(name, message.id, 'bell')&.fetch('status', nil) == Bell::RUNG
    end

    def remind_overdue(roster)
      now = @clock.call
      roster.open_requests.filter_map do |_holder, stored|
        request = stored.message
        sender = Address.parse(request.from, local_host: @host)
        next unless request.overdue?(now) && sender.local?(@host) && @store.address?(sender.name)
        next if @store.marked?(sender.name, request.id, OVERDUE_MARK)

        remind(sender, request)
      end
    end

    def remind(sender, request)
      @postman.post(sender: NAME, recipient: sender, kind: 'message', id: Ulid.derive(request.due_at, request.id),
                    body: "Request #{request.id} to #{request.to} passed its deadline without a reply.")
      @store.mark_once(sender.name, request.id, OVERDUE_MARK)
      request
    rescue Error, SystemCallError => e
      @errors << "could not tell #{sender} that #{request.id} is past its deadline; #{e.message}"
      nil
    end
  end
end
