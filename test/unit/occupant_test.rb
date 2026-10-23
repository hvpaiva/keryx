# frozen_string_literal: true

require 'test_helper'

class OccupantTest < Minitest::Test
  include Factory

  def test_the_record_round_trips
    occupant = build_occupant(pid: 7, started: 'Thu Oct 22 16:35:26 2026', claude_socket: '/run/cc.sock',
                              herdr_socket: '/h.sock', herdr_pane: 'w1:p1')

    assert_equal occupant, Keryx::Occupant.from_record(JSON.parse(JSON.generate(occupant.record)))
  end

  def test_the_record_keeps_the_fraction_of_a_second
    occupant = build_occupant(joined_at: NOW + Rational(123_456_789, 1_000_000_000))
    record = JSON.parse(JSON.generate(occupant.record))

    assert_equal '2026-10-22T17:00:00.123456789Z', record['joined_at']
    assert_equal occupant, Keryx::Occupant.from_record(record)
  end

  def test_a_record_written_in_whole_seconds_still_reads
    record = build_occupant.record.merge('joined_at' => '2026-10-22T17:00:00Z')

    assert_equal NOW, Keryx::Occupant.from_record(record).joined_at
  end

  def test_herdr_needs_both_the_socket_and_the_pane
    assert_predicate build_occupant(herdr_socket: '/h.sock', herdr_pane: 'w1:p1'), :herdr?
    refute_predicate build_occupant(herdr_socket: '/h.sock'), :herdr?
  end

  def test_a_record_written_before_the_start_time_was_kept_still_reads
    record = build_occupant(pid: 7).record.except('started')

    assert_nil Keryx::Occupant.from_record(record).started
  end
end
