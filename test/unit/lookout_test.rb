# frozen_string_literal: true

require 'test_helper'

class LookoutTest < Minitest::Test
  include Factory

  SOCKET = '/h.sock'

  def herdr = @herdr ||= FakeHerdr.new

  def processes = @processes ||= CLIHelpers::FakeProcesses.new([])

  def presence(**occupant) = Keryx::Lookout.new(herdr:, processes:).presence(build_occupant(**occupant))

  def in_pane(agent, **occupant)
    herdr.put(SOCKET, 'w1:p2', agent)
    { herdr_socket: SOCKET, herdr_pane: 'w1:p2', **occupant }
  end

  def codex(session) = Keryx::Herdr::Agent.new(pane: 'w1:p2', kind: 'codex', status: 'unknown', session:)

  def test_a_recorded_process_is_live_while_it_runs_with_its_start_time
    processes.alive << 7

    assert_equal :live, presence(pid: 7, started: 'started 7')
    assert_equal :live, presence(pid: 7)
    assert_equal :gone, presence(pid: 8, started: 'started 8')
    processes.starts[7] = 'started later'

    assert_equal :gone, presence(pid: 7, started: 'started 7')
  end

  def test_a_process_whose_start_ps_cannot_tell_stays_live
    processes.alive << 7
    processes.define_singleton_method(:started) { |_pid| nil }

    assert_equal :live, presence(pid: 7, started: 'started 7')
  end

  def test_without_a_process_the_pane_decides_and_only_what_it_shows_is_gone
    assert_equal :live, presence(harness: 'codex', session_id: 't-1', **in_pane(codex('t-1')))
    assert_equal :gone, presence(harness: 'codex', session_id: 't-1', **in_pane(codex('t-2')))
    assert_equal :gone, presence(harness: 'codex', session_id: 't-1', **in_pane(nil))
    assert_equal :live, presence(harness: 'codex', session_id: 't-1', **in_pane(codex(nil)))
    herdr.unanswered << [SOCKET, 'w1:p2']

    assert_equal :live, presence(harness: 'codex', session_id: 't-1', **in_pane(codex('t-2')))
    assert_equal :unknown, presence(harness: 'codex', session_id: 't-1')
  end
end
