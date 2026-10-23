# frozen_string_literal: true

require_relative 'tokens'

module Keryx
  Context = Data.define(:used, :window)

  class Context
    # Another build may stamp a shape this one does not know, so anything else is no figure rather than an error.
    def self.from_record(data)
      return unless data.is_a?(Hash) && count?(data['used'])

      window = data['window']
      new(used: data['used'], window:) if window.nil? || count?(window)
    end

    # Far above any window today, so a larger count is no figure, whoever stamped it.
    MAX_TOKENS = 1_000_000_000

    def self.count?(value) = value.is_a?(Integer) && value.positive? && value <= MAX_TOKENS

    def share = window && (used * 100r / window).round

    def label = window ? "#{Tokens.short(used)}/#{Tokens.short(window)} #{share}%" : Tokens.short(used)

    def record = { 'used' => used, 'window' => window }
  end
end
