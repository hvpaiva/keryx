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

  def test_short_does_not_round_up_what_ahead_would
    assert_equal '3h', Keryx::Duration.short(14_397)
  end

  def test_ahead_rounds_up_and_takes_the_next_unit_within_fifteen_seconds_of_it
    expected = { 90 => '90s', 104 => '104s', 105 => '2m', 117 => '2m', 119 => '2m', 120 => '2m', 5397 => '90m',
                 5400 => '90m', 7140 => '119m', 7141 => '2h', 7185 => '2h', 7197 => '2h', 7200 => '2h',
                 10_800 => '3h', 10_801 => '4h', 14_397 => '4h', 14_400 => '4h', 169_200 => '47h', 169_201 => '2d',
                 172_785 => '2d', 172_797 => '2d', 172_800 => '2d', 172_801 => '3d' }

    assert_equal(expected, expected.to_h { |seconds, _| [seconds, Keryx::Duration.ahead(seconds)] })
  end

  def test_ahead_rounds_a_fraction_of_a_second_up_and_a_past_moment_to_zero
    assert_equal '1s', Keryx::Duration.ahead(0.2)
    assert_equal '4h', Keryx::Duration.ahead(14_399.6)
    assert_equal '0s', Keryx::Duration.ahead(-5)
  end
end
