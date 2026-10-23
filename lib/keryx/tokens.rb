# frozen_string_literal: true

module Keryx
  module Tokens
    THOUSAND = 1000
    MILLION = 1_000_000

    module_function

    def short(count)
      return count.to_s if count < THOUSAND

      thousands = (count.to_r / THOUSAND).round
      return "#{thousands}k" if thousands < THOUSAND

      "#{format('%.1f', count.to_r / MILLION).delete_suffix('.0')}M"
    end
  end
end
