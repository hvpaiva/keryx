# frozen_string_literal: true

require_relative 'lookout'
require_relative 'processes'

module Keryx
  class Roster
    Entry = Data.define(:name, :role, :occupant, :session, :unread) do
      def ended? = %w[none gone].include?(session)
    end
    ACTIVITY = %w[idle working blocked done].freeze

    def initialize(store:, herdr:, lookout: Lookout.new(herdr:, processes: Processes.new))
      @store = store
      @herdr = herdr
      @lookout = lookout
      @agents = {}
    end

    def entries
      @store.address_names.map do |name|
        record = @store.address(name)
        occupant = @store.occupant(name)
        Entry.new(name:, role: record&.role, occupant:, session: session(occupant), unread: @store.unread(name).size)
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

    def agents_on(socket) = @agents[socket] ||= @herdr.agents(socket).to_h { [it.pane, it] }
  end
end
