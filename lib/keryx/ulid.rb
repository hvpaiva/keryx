# frozen_string_literal: true

require 'digest'
require 'securerandom'

module Keryx
  module Ulid
    ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
    TIME_LENGTH = 10
    RANDOM_LENGTH = 16
    RANDOM_BITS = 80
    FORMAT = /\A[0-9A-HJKMNP-TV-Z]{26}\z/

    module_function

    def generate(time = Time.now, random: SecureRandom)
      milliseconds = (time.to_r * 1000).floor
      encode(milliseconds, TIME_LENGTH) + encode(random.random_number(2**RANDOM_BITS), RANDOM_LENGTH)
    end

    def derive(time, seed)
      random = Digest::SHA256.hexdigest(seed).to_i(16) % (2**RANDOM_BITS)
      encode((time.to_r * 1000).floor, TIME_LENGTH) + encode(random, RANDOM_LENGTH)
    end

    def valid?(text) = FORMAT.match?(text.to_s)

    def encode(number, length)
      Array.new(length) do
        digit = ALPHABET[number % 32]
        number /= 32
        digit
      end.reverse.join
    end
  end
end
