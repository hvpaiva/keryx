# frozen_string_literal: true

require 'test_helper'

class TextTest < Minitest::Test
  NEXT_LINE = [0x85].pack('U')
  RIGHT_TO_LEFT_OVERRIDE = [0x202E].pack('U')
  REPLACEMENT = [0xFFFD].pack('U')

  def test_plain_shows_escape_and_delete_in_caret_notation
    assert_equal '^[[2J^?', Keryx::Text.plain("\e[2J\x7F")
  end

  def test_plain_replaces_c1_and_bidirectional_controls
    assert_equal "a#{REPLACEMENT}b#{REPLACEMENT}c", Keryx::Text.plain("a#{NEXT_LINE}b#{RIGHT_TO_LEFT_OVERRIDE}c")
  end

  def test_plain_keeps_line_feeds_and_tabs_only_with_layout
    assert_equal "a\n\tb", Keryx::Text.plain("a\n\tb", layout: true)
    assert_equal 'a^J^Ib', Keryx::Text.plain("a\n\tb")
  end

  def test_plain_keeps_printable_unicode
    text = "caf#{[0xE9].pack('U')} #{[0x4E2D, 0x6587].pack('U*')}"

    assert_equal text, Keryx::Text.plain(text)
  end

  def test_plain_scrubs_invalid_bytes
    assert_equal "ok#{REPLACEMENT}", Keryx::Text.plain(+"ok\xFF".b)
  end
end
