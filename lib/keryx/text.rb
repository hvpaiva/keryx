# frozen_string_literal: true

module Keryx
  # Text from another session is shown, never obeyed: a message body cannot move the cursor,
  # change colors or rewrite the line before it.
  module Text
    # C1 controls and the bidirectional embedding, override and isolate controls, built from code
    # points so this file stays ASCII.
    INVISIBLE = [*0x80..0x9F, *0x202A..0x202E, *0x2066..0x2069].pack('U*').freeze
    CONTROL = /[\x00-\x1F\x7F#{INVISIBLE}]/
    LAYOUT = "\t\n"
    REPLACEMENT = [0xFFFD].pack('U').freeze

    module_function

    # C0 characters and DEL take caret notation (ESC is ^[), the rest the replacement character.
    # `layout` keeps line feeds and tabs, for a body printed in full.
    def plain(text, layout: false)
      String.new(text.to_s, encoding: Encoding::UTF_8).scrub(REPLACEMENT).gsub(CONTROL) do |char|
        next char if layout && LAYOUT.include?(char)

        char.ord < 0x80 ? "^#{((char.ord + 0x40) & 0x7F).chr}" : REPLACEMENT
      end
    end
  end
end
