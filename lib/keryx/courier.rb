# frozen_string_literal: true

require_relative 'address'
require_relative 'bell'
require_relative 'error'
require_relative 'identity'
require_relative 'postman'
require_relative 'retirement'
require_relative 'tokens'
require_relative 'ulid'

module Keryx
  class Courier
    Round = Data.define(:forwarded, :rung, :overdue, :context, :errors)
    Notice = Data.define(:name, :recipient, :stage, :context, :ceiling)
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
        sender = Address.parse(request.from)
        next unless request.overdue?(now) && sender.local?(@host) && @store.address?(sender.key)
        next if @store.marked?(sender.key, request.id, OVERDUE_MARK)

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
      director = Address.from_name(occupant.director, host: @host) if occupant.director
      director ||= oldest_request(roster, name)&.then { Address.parse(it.from) }
      director &&= settled(roster, director)
      [Address.from_name(name, host: @host), director].compact.uniq
    end

    # A director that join --force displaced is told at its session address until that session leaves, and then at
    # the address it was displaced from, whose holder took its work.
    def settled(roster, address)
      live = ->(name) { roster.live?(@store.reporting { @store.occupant(name) }) }
      address.local?(@host) && Postman.session_left(@store, address, live) ? address.stable : address
    end

    # Only the requests the incarnation lists, so neither the holder nor a displaced session takes the other's work.
    def oldest_request(roster, name)
      @open_requests ||= roster.open_requests
      @store.listed(name, @open_requests).map(&:message).min_by(&:id)
    end

    # Once per recipient for each join and ceiling, and never nearing the ceiling once told it reached it. The first
    # courier to tell a notice claims its id as it writes it, and every later post uses that id, so the store keeps
    # one copy however many couriers or rounds post it. Only the courier that writes the mark reports it.
    def tell(name, recipient, occupant, context, stage)
      mark = context_mark(occupant, stage, recipient)
      return if held_back?(name, recipient, occupant, stage, mark)
      return retired(name, recipient, mark) if recipient.local?(@host) && @store.retired?(recipient.key)

      body = notice(name, context, occupant.ceiling, stage)
      claim = -> { notice_id(name, recipient, occupant, stage) }
      return unless @postman.post(sender: Identity.system(recipient), recipient:, kind: 'message', body:, claim:)
      return unless @store.mark_once(name, mark, CONTEXT_MARK)

      Notice.new(name:, recipient: recipient.to_s, stage:, context:, ceiling: occupant.ceiling)
    rescue Error, SystemCallError => e
      @errors << "could not tell #{recipient} about the context of #{full(name)}; #{e.message}"
      nil
    end

    # Told already, kept back by the ceiling told before it, or about a join that no longer holds the address.
    def held_back?(name, recipient, occupant, stage, mark)
      @store.marked?(name, mark, CONTEXT_MARK) || superseded?(name, recipient, occupant, stage, CONTEXT_MARK) ||
        !same_join?(@store.occupant(name), occupant)
    end

    # A recipient here that is retired takes no mail, and trying again would report it in every round, so the notice
    # counts as told, and the courier that marks it says once that it did not tell it.
    def retired(name, recipient, mark)
      return unless @store.mark_once(name, mark, CONTEXT_MARK)

      @errors << "did not tell #{recipient} about the context of #{full(name)}; " \
                 "#{format(Retirement::RETIRED, recipient)}"
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

    # Keyed on the join itself, so two joins that share an instant and a ceiling are two.
    def context_mark(occupant, stage, recipient)
      join = [*JOIN.map { occupant.public_send(it) }, occupant.session].join(' ')
      Ulid.derive(occupant.joined_at, "context #{stage} #{recipient} #{join}")
    end

    # Asked in the post's hold of the occupants lock, and none for a notice no longer due. A ceiling's id sorts after
    # the id claimed for the notice near it to the same recipient for the same join, so no recipient reads that
    # notice after the ceiling's, whatever the clock says, unless that claim is damaged.
    def notice_id(name, recipient, occupant, stage)
      return unless due?(name, recipient, occupant, stage)

      id = Ulid.generate(@clock.call)
      id = [id, after_near(name, recipient, occupant)].compact.max if stage == :ceiling
      claim(name, recipient, occupant, stage, id)
    end

    # Every courier claims in the hold, so the fresh id written over a damaged claim is the one the next courier reads
    # back, and the store keeps one copy. A notice posted under the damaged id and never marked goes out again, which
    # costs less than a notice held back for good. The damage is a problem and an error of the round.
    def claim(name, recipient, occupant, stage, id)
      mark = context_mark(occupant, stage, recipient)
      @store.claim(name, mark, CONTEXT_CLAIM, id) { Ulid.valid?(it) }
    rescue Store::Damaged => e
      @store.problems << e.message
      @errors << "the #{stage} notice of #{full(name)} to #{recipient} writes a fresh id over its damaged claim; " \
                 "#{e.message}"
      @store.reclaim(name, mark, CONTEXT_CLAIM, id)
    end

    # A damaged claim can no longer place the ceiling after the notice near it. Losing the ceiling costs more than that
    # order, so the ceiling takes a fresh id, and the damage is a problem and an error of the round.
    def after_near(name, recipient, occupant)
      mark = context_mark(occupant, :near, recipient)
      near = @store.claimed(name, mark, CONTEXT_CLAIM) { Ulid.valid?(it) } or return
      Ulid.after(near)
    rescue Error => e
      @store.problems << e.message
      @errors << "the ceiling notice of #{full(name)} to #{recipient} takes a fresh id and may sort before the " \
                 "notice near it; #{e.message}"
      nil
    end

    def full(name) = Address.from_name(name, host: @host)

    def notice(name, context, ceiling, stage)
      used = "#{full(name)} has #{Tokens.short(context.used)} tokens of context in use, " \
             "#{context.share_of(ceiling)}% of its #{Tokens.short(ceiling)} ceiling."
      return "#{used} It reached its ceiling and should reach a stopping point now." if stage == :ceiling

      "#{used} It should reach a stopping point."
    end

    def remind(sender, request)
      @postman.post(sender: Identity.system(sender), recipient: sender, kind: 'message',
                    id: Ulid.derive(request.due_at, request.id),
                    body: "Request #{request.id} to #{request.to} passed its deadline without a reply.")
      @store.mark_once(sender.key, request.id, OVERDUE_MARK)
      request
    rescue Error, SystemCallError => e
      @errors << "could not tell #{sender} that #{request.id} is past its deadline; #{e.message}"
      nil
    end
  end
end
