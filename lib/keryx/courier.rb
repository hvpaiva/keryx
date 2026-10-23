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
    CONTEXT_CLAIM = 'context-id'
    # What a join sets and a command that records the session's process again keeps.
    JOIN = %i[harness session_id joined_at ceiling].freeze

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
      @measure = @meter.call
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
        next unless entry.ringable?

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

      context = @measure.read(entry.occupant)
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

    # Once per recipient for each join and ceiling, and never nearing the ceiling once told it reached it. The first
    # courier to tell a notice claims its id as it writes it, and every later post uses that id, so the store keeps
    # one copy however many couriers or rounds post it. Only the courier that writes the mark reports it.
    def tell(name, recipient, occupant, context, stage)
      mark = context_mark(occupant, stage, recipient)
      return if @store.marked?(name, mark, CONTEXT_MARK) || superseded?(name, recipient, occupant, stage, CONTEXT_MARK)
      return unless same_join?(@store.occupant(name), occupant)

      body = notice(name, context, occupant.ceiling, stage)
      claim = -> { notice_id(name, recipient, occupant, stage) }
      return unless @postman.post(sender: NAME, recipient:, kind: 'message', body:, claim:)
      return unless @store.mark_once(name, mark, CONTEXT_MARK)

      Notice.new(name:, recipient: recipient.to_s, stage:, context:, ceiling: occupant.ceiling)
    rescue Error, SystemCallError => e
      @errors << "could not tell #{recipient} about the context of #{name}@#{@host}; #{e.message}"
      nil
    end

    # A ceiling notice claims its id in the hold that writes it and is marked only after it, so its claim is what keeps
    # the notice near it back.
    def due?(name, recipient, occupant, stage)
      same_join?(@store.occupant(name), occupant) && !superseded?(name, recipient, occupant, stage, CONTEXT_CLAIM)
    end

    def superseded?(name, recipient, occupant, stage, kind)
      stage == :near && @store.marked?(name, context_mark(occupant, :ceiling, recipient), kind)
    end

    # A session that joined the address while the figure was read is not the session the figure belongs to.
    def same_join?(current, occupant) = current && JOIN.all? { current.public_send(it) == occupant.public_send(it) }

    def context_mark(occupant, stage, recipient)
      Ulid.derive(occupant.joined_at, "context #{stage} #{occupant.ceiling} #{recipient}")
    end

    # Asked in the post's hold of the occupants lock, and none for a notice no longer due. A ceiling's id sorts after
    # the id claimed for the notice near it to the same recipient for the same join, so no recipient reads that
    # notice after the ceiling's, whatever the clock says.
    def notice_id(name, recipient, occupant, stage)
      return unless due?(name, recipient, occupant, stage)

      id = Ulid.generate(@clock.call)
      id = [id, after_near(name, recipient, occupant)].compact.max if stage == :ceiling
      mark = context_mark(occupant, stage, recipient)
      id = @store.claim(name, mark, CONTEXT_CLAIM, id)
      return id if Ulid.valid?(id)

      raise Error, "the id claimed for the notice #{mark} is damaged"
    end

    def after_near(name, recipient, occupant)
      mark = context_mark(occupant, :near, recipient)
      near = @store.claimed(name, mark, CONTEXT_CLAIM) or return
      Ulid.after(near) or raise Error, "the id claimed for the notice #{mark} is damaged"
    end

    def notice(name, context, ceiling, stage)
      used = "#{name}@#{@host} has #{Tokens.short(context.used)} tokens of context in use, " \
             "#{context.share_of(ceiling)}% of its #{Tokens.short(ceiling)} ceiling."
      return "#{used} It reached its ceiling and should reach a stopping point now." if stage == :ceiling

      "#{used} It should reach a stopping point."
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
