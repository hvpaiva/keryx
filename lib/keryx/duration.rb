# frozen_string_literal: true

require_relative 'error'

module Keryx
  # The durations --within and --timeout take, such as 90s, 30m or 1h30m, and the ages listings
  # print.
  module Duration
    UNITS = { 'd' => 86_400, 'h' => 3600, 'm' => 60, 's' => 1 }.freeze
    FORMAT = /\A(?:\d+[dhms])+\z/
    PART = /(\d+)([dhms])/

    module_function

    def parse(text)
      unless FORMAT.match?(text.to_s)
        raise UsageError, "invalid duration #{text.to_s.inspect}: use a number and a unit (s, m, h, d), as in 30m"
      end

      seconds = text.scan(PART).sum { |amount, unit| Integer(amount, 10) * UNITS.fetch(unit) }
      raise UsageError, "invalid duration #{text.inspect}: it must be longer than zero" if seconds.zero?

      seconds
    end

    # One unit, rounded down, the way kubectl prints ages: 45s, 12m, 5h, 3d. A negative span
    # prints as 0s.
    def short(seconds)
      seconds = [seconds.to_i, 0].max
      return "#{seconds}s" if seconds < 120
      return "#{seconds / 60}m" if seconds < 7200
      return "#{seconds / 3600}h" if seconds < 172_800

      "#{seconds / 86_400}d"
    end
  end
end
