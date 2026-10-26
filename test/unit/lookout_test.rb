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

  def claude(session) = Keryx::Herdr::Agent.new(pane: 'w1:p2', kind: 'claude', status: 'working', session:)

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

  def test_a_session_id_herdr_reports_never_matches_a_record_without_one
    processes.alive << 7
    herdr.foregrounds[[SOCKET, 'w1:p2']] = 7
    occupant = build_occupant(harness: 'codex', session_id: nil, pid: 7, started: 'started 7',
                              **in_pane(codex('t-2')))
    sighting = Keryx::Lookout.new(herdr:, processes:).in_pane(occupant)

    assert_equal :unproven, sighting.verdict
    assert_equal 'pane w1:p2 runs thread t-2, and the session that joined recorded no thread', sighting.detail
    herdr.put(SOCKET, 'w1:p2', codex(nil))

    assert_predicate Keryx::Lookout.new(herdr:, processes:).in_pane(occupant), :there?
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

  def test_a_session_relaunched_in_its_pane_stays_live_after_its_process_ended
    relaunched = { harness: 'claude', session_id: 's-1', pid: 7, started: 'started 7' }

    assert_equal :gone, presence(**relaunched)
    assert_equal :live, presence(**relaunched, **in_pane(claude('s-1')))
    processes.alive << 7
    processes.starts[7] = 'started later'

    assert_equal :live, presence(**relaunched, **in_pane(claude('s-1')))
  end

  def test_an_ended_process_whose_pane_shows_nothing_or_another_session_is_gone
    ended = { harness: 'claude', session_id: 's-1', pid: 7, started: 'started 7' }

    assert_equal :gone, presence(**ended, **in_pane(nil))
    assert_equal :gone, presence(**ended, **in_pane(claude('s-2')))
    assert_equal :gone, presence(**ended, **in_pane(claude(nil)))
    assert_equal :gone, presence(**ended, **in_pane(codex('s-1')))
    assert_equal :gone, presence(**ended.except(:session_id), session_id: nil, **in_pane(claude(nil)))
    herdr.unanswered << [SOCKET, 'w1:p2']

    assert_equal :gone, presence(**ended, **in_pane(claude('s-1')))
  end

  def test_a_listing_the_caller_holds_answers_for_the_pane_instead_of_herdr
    occupant = build_occupant(harness: 'claude', session_id: 's-1', pid: 7, started: 'started 7', **in_pane(nil))
    lookout = Keryx::Lookout.new(herdr:, processes:)

    assert_equal :live, lookout.presence(occupant) { claude('s-1') }
    assert_equal :gone, lookout.presence(occupant) { Keryx::Herdr::NONE }
    assert_equal :gone, lookout.presence(occupant)
  end
end
