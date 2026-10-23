# frozen_string_literal: true

require_relative 'address'
require_relative 'bell'
require_relative 'error'
require_relative 'tokens'
require_relative 'ulid'

module Keryx
  class Courier
    Round = Data.define(:forwarded, :rung, :overdue, :context, :errors)
    Notice = Data.define(:name, :recipient, :stage, :context, :ceiling)
    NAME = 'keryx'
    OVERDUE_MARK = 'overdue'
    CONTEXT_MARK = 'context'
    UNREACHABLE = %w[none gone].freeze

    def initialize(store:, forwarder:, bell:, roster:, postman:, host:, clock:, meter:)
      @store = store
      @forwarder = forwarder
      @bell = bell
      @roster = roster
      @postman = postman
      @host = host
      @clock = clock
      @meter = meter
    end

    def round
      roster = @roster.call
      @errors = []
      @open_requests = nil
      Round.new(forwarded: forward, rung: ring_again(roster), overdue: remind_overdue(roster),
                context: tell_context(roster), errors: @errors)
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

    def tell_context(roster)
      roster.entries.flat_map do |entry|
        context, stage = measured(entry)
        next [] unless stage

        recipients(roster, entry.name, entry.occupant).filter_map do |recipient|
          tell(entry.name, recipient, entry.occupant, context, stage)
        end
      end
    end

    # Only a session with a ceiling is read, and only while it runs.
    def measured(entry)
      ceiling = entry.occupant&.ceiling
      return if ceiling.nil? || entry.ended?

      context = @meter.read(entry.occupant)
      [context, context&.stage(ceiling)]
    end

    # The director recorded at spawn, or else the sender of the oldest request the session still has to answer.
    def recipients(roster, name, occupant)
      director = Address.new(name: occupant.director, host: @host) if occupant.director
      director ||= oldest_request(roster, name)&.then { Address.parse(it.from, local_host: @host) }
      [Address.new(name:, host: @host), director].compact.uniq
    end

    def oldest_request(roster, name)
      @open_requests ||= roster.open_requests
      @open_requests.filter_map { |holder, stored| stored.message if holder == name }.min_by(&:id)
    end

    # Once per recipient for each join and ceiling, and never nearing the ceiling once told it reached it. The notice
    # takes the time it is sent, so the recipient reads them in order.
    def tell(name, recipient, occupant, context, stage)
      mark = context_mark(occupant, stage, recipient)
      return if @store.marked?(name, mark, CONTEXT_MARK)
      return if stage == :near && @store.marked?(name, context_mark(occupant, :ceiling, recipient), CONTEXT_MARK)

      body = notice(name, context, occupant.ceiling, stage)
      @postman.post(sender: NAME, recipient:, kind: 'message', body:)
      @store.mark_once(name, mark, CONTEXT_MARK)
      Notice.new(name:, recipient: recipient.to_s, stage:, context:, ceiling: occupant.ceiling)
    rescue Error, SystemCallError => e
      @errors << "could not tell #{recipient} about the context of #{name}@#{@host}; #{e.message}"
      nil
    end

    def context_mark(occupant, stage, recipient)
      Ulid.derive(occupant.joined_at, "context #{stage} #{occupant.ceiling} #{recipient}")
    end

    def notice(name, context, ceiling, stage)
      used = "#{name}@#{@host} has #{Tokens.short(context.used)} tokens of context in use"
      return "#{used} and reached its #{Tokens.short(ceiling)} ceiling. It should reach a stopping point now." if
        stage == :ceiling

      "#{used}, #{(context.used * 100r / ceiling).round}% of its #{Tokens.short(ceiling)} ceiling. It should reach a " \
        'stopping point.'
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
