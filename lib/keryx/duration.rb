# frozen_string_literal: true

require_relative 'error'

module Keryx
  module Duration
    UNITS = { 'd' => 86_400, 'h' => 3600, 'm' => 60, 's' => 1 }.freeze
    FORMAT = /\A(?:\d+[dhms])+\z/
    PART = /(\d+)([dhms])/
    SCALE = [['s', 1, 120], ['m', 60, 120], ['h', 3600, 48], ['d', 86_400, nil]].freeze
    GRACE_SECONDS = 15

    module_function

    def parse(text)
      unless FORMAT.match?(text.to_s)
        raise UsageError, "invalid duration #{text.to_s.inspect}: use a number and a unit (s, m, h, d), as in 30m"
      end

      seconds = text.scan(PART).sum { |amount, unit| Integer(amount, 10) * UNITS.fetch(unit) }
      raise UsageError, "invalid duration #{text.inspect}: it must be longer than zero" if seconds.zero?

      seconds
    end

    def short(seconds) = scaled(seconds, :floor, 0)

    # Rounded up, so a deadline reads as it was set until a whole unit passes, and seconds give way to minutes early.
    def ahead(seconds) = scaled(seconds, :ceil, GRACE_SECONDS)

    def scaled(seconds, rounding, grace)
      span = [seconds.to_r, 0].max
      SCALE.each do |unit, size, limit|
        count = (span / size).public_send(rounding)
        return "#{count}#{unit}" if limit.nil? || (count < limit && span + grace < limit * size)
      end
    end
    private_class_method :scaled
  end
end
