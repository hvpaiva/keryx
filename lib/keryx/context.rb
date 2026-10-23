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

    def against(ceiling) = "#{Tokens.short(used)} #{(used * 100r / ceiling).round}% of #{Tokens.short(ceiling)}"

    # Whole numbers only, so where 80% of a ceiling falls never depends on rounding.
    def stage(ceiling)
      if used >= ceiling then :ceiling
      elsif used * 5 >= ceiling * 4 then :near
      end
    end

    def record = { 'used' => used, 'window' => window }
  end
end
