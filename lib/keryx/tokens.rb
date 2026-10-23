# frozen_string_literal: true

require_relative 'error'

module Keryx
  module Tokens
    THOUSAND = 1000
    MILLION = 1_000_000
    FORMAT = /\A(?<number>\d+(?:\.\d+)?)(?<unit>[kKmM]?)\z/
    SCALE = { '' => 1, 'k' => THOUSAND, 'm' => MILLION }.freeze

    module_function

    def parse(text)
      match = FORMAT.match(text.to_s)
      count = match && (match[:number].to_r * SCALE.fetch(match[:unit].downcase)).round
      return count if count&.positive?

      raise UsageError, "invalid token count #{text.to_s.inspect}: a number with an optional k or m, such as 125k or 1m"
    end

    def short(count)
      return count.to_s if count < THOUSAND

      thousands = (count.to_r / THOUSAND).round
      return "#{thousands}k" if thousands < THOUSAND

      "#{format('%.1f', count.to_r / MILLION).delete_suffix('.0')}M"
    end
  end
end
