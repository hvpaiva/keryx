# frozen_string_literal: true

require 'securerandom'

module Keryx
  # Message ids. A ULID is 26 characters of Crockford base32: 48 bits of milliseconds, then 80
  # random bits. Ids sort by creation time, so a directory listing is already in order, and they
  # are safe as file names.
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
