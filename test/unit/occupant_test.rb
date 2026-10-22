# frozen_string_literal: true

require 'test_helper'

class OccupantTest < Minitest::Test
  include Factory

  Killer = Struct.new(:error) do
    def kill(_signal, _pid)
      raise error if error

      1
    end
  end

  def test_the_record_round_trips
    occupant = build_occupant(pid: 7, claude_socket: '/run/cc.sock', herdr_socket: '/h.sock', herdr_pane: 'w1:p1')

    assert_equal occupant, Keryx::Occupant.from_record(JSON.parse(JSON.generate(occupant.record)))
  end

  def test_herdr_needs_both_the_socket_and_the_pane
    assert_predicate build_occupant(herdr_socket: '/h.sock', herdr_pane: 'w1:p1'), :herdr?
    refute_predicate build_occupant(herdr_socket: '/h.sock'), :herdr?
  end

  def test_presence_reads_the_process_table
    assert_equal :live, build_occupant(pid: 7).presence(process: Killer.new(nil))
    assert_equal :gone, build_occupant(pid: 7).presence(process: Killer.new(Errno::ESRCH))
    assert_equal :live, build_occupant(pid: 7).presence(process: Killer.new(Errno::EPERM))
    assert_equal :unknown, build_occupant.presence
  end
end
