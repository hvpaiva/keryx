# frozen_string_literal: true

require 'test_helper'

class DurationTest < Minitest::Test
  def test_parse_reads_one_unit_or_several
    assert_equal 90, Keryx::Duration.parse('90s')
    assert_equal 1800, Keryx::Duration.parse('30m')
    assert_equal 5400, Keryx::Duration.parse('1h30m')
    assert_equal 86_400 + 60, Keryx::Duration.parse('1d1m')
  end

  def test_parse_rejects_a_bare_number_an_unknown_unit_and_zero
    %w[30 30x 1.5h -5m 0m].each do |text|
      error = assert_raises(Keryx::UsageError) { Keryx::Duration.parse(text) }

      assert_includes error.message, text.inspect
    end
  end

  def test_short_prints_one_unit_rounded_down
    assert_equal '45s', Keryx::Duration.short(45)
    assert_equal '119s', Keryx::Duration.short(119)
    assert_equal '2m', Keryx::Duration.short(120)
    assert_equal '119m', Keryx::Duration.short(7199)
    assert_equal '47h', Keryx::Duration.short(172_799)
    assert_equal '3d', Keryx::Duration.short(3 * 86_400)
  end

  def test_short_prints_a_negative_span_as_zero
    assert_equal '0s', Keryx::Duration.short(-5)
  end
end
