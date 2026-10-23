# frozen_string_literal: true

require 'test_helper'

class UlidTest < Minitest::Test
  FixedRandom = Struct.new(:value) do
    def random_number(_limit) = value
  end

  def test_the_time_part_encodes_milliseconds_since_the_epoch
    id = Keryx::Ulid.generate(Time.at(Rational(1_469_918_176_385, 1000)), random: FixedRandom.new(0))

    assert_equal '01ARYZ6S41', id[0, 10]
    assert_equal '0' * 16, id[10, 16]
  end

  def test_ids_sort_by_creation_time
    earlier = Keryx::Ulid.generate(Time.at(1_000), random: FixedRandom.new((2**80) - 1))
    later = Keryx::Ulid.generate(Time.at(1_001), random: FixedRandom.new(0))

    assert_operator earlier, :<, later
  end

  def test_generated_ids_are_valid_and_distinct
    ids = Array.new(100) { Keryx::Ulid.generate }

    assert(ids.all? { Keryx::Ulid.valid?(it) })
    assert_equal 100, ids.uniq.size
  end

  def test_valid_rejects_letters_outside_crockford_base32
    refute Keryx::Ulid.valid?("01ARYZ6S41#{'I' * 16}")
    refute Keryx::Ulid.valid?('01ARYZ6S41')
    refute Keryx::Ulid.valid?(nil)
  end

  def test_after_gives_the_next_id_in_their_order_and_carries_into_the_next_millisecond
    id = Keryx::Ulid.generate(Time.at(1_000), random: FixedRandom.new(30))
    last_of_its_millisecond = Keryx::Ulid.generate(Time.at(1_000), random: FixedRandom.new((2**80) - 1))

    assert_equal "#{id[0, 25]}Z", Keryx::Ulid.after(id)
    assert_equal "#{id[0, 24]}10", Keryx::Ulid.after(Keryx::Ulid.after(id))
    assert_equal Keryx::Ulid.generate(Time.at(Rational(1_000_001, 1000)), random: FixedRandom.new(0)),
                 Keryx::Ulid.after(last_of_its_millisecond)
  end

  def test_after_gives_nothing_after_the_last_id_or_after_what_is_no_id
    assert_nil Keryx::Ulid.after('Z' * 26)
    assert_nil Keryx::Ulid.after('not an id')
    assert_nil Keryx::Ulid.after(nil)
  end

  def test_valid_rejects_a_number_that_prints_like_an_id
    refute Keryx::Ulid.valid?(12_345_678_901_234_567_890_123_456)
  end
end
