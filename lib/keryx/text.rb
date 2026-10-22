# frozen_string_literal: true

module Keryx
  module Text
    INVISIBLE = [*0x80..0x9F, *0x202A..0x202E, *0x2066..0x2069].pack('U*').freeze
    CONTROL = /[\x00-\x1F\x7F#{INVISIBLE}]/
    LAYOUT = "\t\n"
    REPLACEMENT = [0xFFFD].pack('U').freeze

    module_function

    def plain(text, layout: false)
      String.new(text.to_s, encoding: Encoding::UTF_8).scrub(REPLACEMENT).gsub(CONTROL) do |char|
        next char if layout && LAYOUT.include?(char)

        char.ord < 0x80 ? "^#{((char.ord + 0x40) & 0x7F).chr}" : REPLACEMENT
      end
    end
  end
end
