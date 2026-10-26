# frozen_string_literal: true

require_relative 'address'

module Keryx
  # What spawn records about the session it starts, so that the session takes the address spawn ran as for its
  # director when it joins, even after spawn gave up waiting. expect records the same for a session another launcher
  # starts.
  Spawned = Data.define(:director, :harness, :herdr_socket, :herdr_pane)

  class Spawned
    FIELDS = %w[director harness herdr_socket herdr_pane].freeze

    def self.from_record(data)
      return unless data.is_a?(Hash) && FIELDS.all? { data[it].is_a?(String) } && Address.name?(data['director'])

      new(**FIELDS.to_h { [it.to_sym, data[it]] })
    end

    def record = to_h.transform_keys(&:to_s)

    # One socket spelled another way, such as /./h.sock or //h.sock for /h.sock, takes one lexical form. Links are not
    # followed, since herdr gives a pane its socket as it was given and the join reads that.
    def self.socket(path) = path.to_s.start_with?('/') ? File.expand_path(path.squeeze('/')) : path

    # The session spawn started runs the harness spawn started, in the pane it placed.
    def started?(occupant)
      occupant.harness == harness && occupant.herdr_pane == herdr_pane &&
        Spawned.socket(occupant.herdr_socket) == Spawned.socket(herdr_socket)
    end
  end
end
