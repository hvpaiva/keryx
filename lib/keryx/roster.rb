# frozen_string_literal: true

require_relative 'lookout'
require_relative 'processes'

module Keryx
  class Roster
    Entry = Data.define(:name, :role, :occupant, :session, :unread) do
      def ended? = %w[none gone].include?(session)

      # The bell reads the occupant again, so a session whose occupant could not be read is never rung.
      def ringable? = !occupant.nil? && !ended?
    end
    ACTIVITY = %w[idle working blocked done].freeze
    UNKNOWN = 'unknown'

    def initialize(store:, herdr:, lookout: Lookout.new(herdr:, processes: Processes.new))
      @store = store
      @herdr = herdr
      @lookout = lookout
      @agents = {}
    end

    def entries
      @store.address_names.map do |name|
        role = @store.reporting { @store.address(name)&.role }
        Entry.new(name:, role:, **holder(name), unread: @store.unread(name).size)
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

    def open_requests
      all = @store.all_messages
      replies = all.map { it.last.message }.select(&:in_reply_to).group_by(&:in_reply_to)
      all.select do |_name, stored|
        request = stored.message
        request.request? && replies.fetch(request.id, []).none? { Roster.settles?(it, request) }
      end
    end

    def settlement(request) = @store.all_messages.map { it.last.message }.find { Roster.settles?(it, request) }

    def self.settles?(message, request) = message.answers?(request) || message.withdraws?(request)

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
