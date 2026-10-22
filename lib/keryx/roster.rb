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
      answered = all.filter_map { |_name, stored| stored.message.in_reply_to }.to_set
      all.select { |_name, stored| stored.message.request? && !answered.include?(stored.message.id) }
    end

    private

    def agents_on(socket) = @agents[socket] ||= @herdr.agents(socket).to_h { [it.pane, it] }
  end
end
