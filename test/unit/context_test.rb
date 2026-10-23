# frozen_string_literal: true

require 'test_helper'

class ContextTest < Minitest::Test
  def context(used, window = nil) = Keryx::Context.new(used:, window:)

  def test_tokens_read_short_in_thousands_and_millions
    assert_equal(%w[0 850 999 1k 137k 999k 1M 1M 2.5M 12M],
                 [0, 850, 999, 1000, 137_421, 999_499, 999_500, 1_048_576, 2_500_000, 12_000_000]
                   .map { Keryx::Tokens.short(it) })
  end

  def test_a_label_shows_the_window_and_its_share_only_when_one_is_known
    assert_equal '303k', context(303_421).label
    assert_equal '137k/258k 53%', context(137_000, 258_400).label
    assert_equal 53, context(137_000, 258_400).share
    assert_nil context(303_421).share
  end

  def test_a_record_round_trips_and_ignores_keys_it_does_not_know
    record = context(137_000, 258_400).record

    assert_equal({ 'used' => 137_000, 'window' => 258_400 }, record)
    assert_equal context(137_000, 258_400), Keryx::Context.from_record(record.merge('ceiling' => 1))
    assert_equal context(5), Keryx::Context.from_record('used' => 5)
  end

  def test_a_shape_it_does_not_know_is_no_figure
    [nil, 'big', [], { 'used' => 0 }, { 'used' => -1 }, { 'used' => '5' }, { 'used' => 5.5 },
     { 'used' => 5, 'window' => 0 }, { 'used' => 5, 'window' => '9' }, { 'window' => 9 }]
      .each { assert_nil Keryx::Context.from_record(it), it.inspect }
  end
end
