# frozen_string_literal: true

module Keryx
  class Roster
    Entry = Data.define(:name, :role, :occupant, :session, :unread)

    def initialize(store:, herdr:, process: Process)
      @store = store
      @herdr = herdr
      @process = process
      @agents = {}
    end

    def entries
      @store.address_names.map do |name|
        record = @store.address(name)
        occupant = @store.occupant(name)
        Entry.new(name:, role: record&.role, occupant:, session: session(occupant), unread: @store.unread(name).size)
      end
    end

    def session(occupant)
      return 'none' unless occupant

      presence = occupant.presence(process: @process)
      return 'gone' if presence == :gone

      agent = occupant.herdr? && agents_on(occupant.herdr_socket)[occupant.herdr_pane]
      return agent.status if agent && agent.kind == occupant.harness

      presence.to_s
    end

    def open_requests
      all = @store.all_messages
      replies = all.map { it.last.message }.select(&:reply?).group_by(&:in_reply_to)
      all.select do |_name, stored|
        request = stored.message
        request.request? && replies.fetch(request.id, []).none? { it.answers?(request) }
      end
    end

    private

    def agents_on(socket) = @agents[socket] ||= @herdr.agents(socket).to_h { [it.pane, it] }
  end
end
