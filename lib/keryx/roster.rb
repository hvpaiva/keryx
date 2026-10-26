# frozen_string_literal: true

require_relative 'lookout'
require_relative 'processes'
require_relative 'store'

module Keryx
  class Roster
    Entry = Data.define(:name, :role, :occupant, :session, :unread) do
      def ended? = %w[none gone].include?(session)

      # The bell reads the occupant again, so a session whose occupant could not be read is never rung.
      def ringable? = !occupant.nil? && !ended?

      # Nobody holds the address and nobody writes to it: no session, nothing unread and no request waiting on it.
      def quiet?(waiting) = ended? && unread.zero? && !waiting.include?(name)
    end
    ACTIVITY = %w[idle working blocked done].freeze
    UNKNOWN = 'unknown'

    def initialize(store:, herdr:, lookout: Lookout.new(herdr:, processes: Processes.new))
      @store = store
      @herdr = herdr
      @lookout = lookout
      @agents = {}
    end

    # One row for each bound incarnation: the holder by the address's key, then each session join --force displaced.
    def entries
      @store.current_names.flat_map do |name|
        role = @store.reporting { @store.address(name)&.role }
        @store.incarnations(name).map { Entry.new(name: it, role:, **holder(it), unread: @store.unread(it).size) }
      end
    end

    # Whether the session lives comes from its process or its pane; herdr's activity only describes a live one.
    def session(occupant)
      return 'none' unless occupant

      presence = @lookout.presence(occupant)
      return presence.to_s unless presence == :live

      agent = occupant.herdr? && agents_on(occupant.herdr_socket)[occupant.herdr_pane]
      agent && agent.kind == occupant.harness && ACTIVITY.include?(agent.status) ? agent.status : 'live'
    end

    def live?(occupant) = !occupant.nil? && @lookout.presence(occupant) == :live

    # A request its recipient wrote a message in the thread of stays open, in the state taken.
    def open_requests
      all = @store.all_messages
      responses = all.map { it.last.message }.select(&:in_reply_to).group_by(&:in_reply_to)
      all.filter_map do |holder, stored|
        request = stored.message
        found = responses.fetch(request.id, [])
        next unless Roster.open?(request, found)

        [holder, Roster.taken?(stored, found) ? stored.with(state: :taken) : stored]
      end
    end

    # A request to its own sender's address cannot tell the sender's send --on from the recipient's send --re by the
    # message, so it counts as taken only once read, as send --re leaves it and send --on does not.
    def self.taken?(stored, responses)
      request = stored.message
      responses.any? { it.takes?(request) } && (request.from != request.to || stored.state != :unread)
    end

    def settlement(request) = @store.all_messages.map { it.last.message }.find { Roster.settles?(it, request) }

    def self.settles?(message, request) = message.answers?(request) || message.withdraws?(request)

    def self.open?(request, responses) = answerable?(request) && responses.none? { settles?(it, request) }

    # A request with an address from before team names at either end is over, since nothing can answer or withdraw it
    # any more.
    def self.answerable?(request) = request.request? && !request.teamless

    # The addresses here that open requests wait on, as their recipient or as the address that sent them from here.
    def self.waiting_on(open)
      open.flat_map { |holder, stored| [holder, Store.sender_here(holder, stored.message)] }.compact.to_set
    end

    private

    # An occupant that cannot be read shows no session to look for, ring or measure, so its session is unknown.
    def holder(name)
      @store.reporting({ occupant: nil, session: UNKNOWN }) do
        occupant = @store.occupant(name)
        { occupant:, session: session(occupant) }
      end
    end

    def agents_on(socket) = @agents[socket] ||= @herdr.agents(socket).to_h { [it.pane, it] }
  end
end
