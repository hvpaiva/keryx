# frozen_string_literal: true

require_relative 'address'

module Keryx
  # What spawn records about the session it starts, so that the session takes the address spawn ran as for its
  # director when it joins, even after spawn gave up waiting.
  Spawned = Data.define(:director, :harness, :herdr_socket, :herdr_pane)

  class Spawned
    FIELDS = %w[director harness herdr_socket herdr_pane].freeze

    def self.from_record(data)
      return unless data.is_a?(Hash) && FIELDS.all? { data[it].is_a?(String) } && Address.name?(data['director'])

      new(**FIELDS.to_h { [it.to_sym, data[it]] })
    end

    def record = to_h.transform_keys(&:to_s)

    # The session spawn started runs the harness spawn started, in the pane it placed.
    def started?(occupant)
      occupant.harness == harness && occupant.herdr_socket == herdr_socket && occupant.herdr_pane == herdr_pane
    end
  end
end
