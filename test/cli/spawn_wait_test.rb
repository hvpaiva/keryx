# frozen_string_literal: true

require 'test_helper'

class SpawnWaitTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers

  def test_a_dialog_is_reported_once_and_the_join_still_counts
    herdr.start_outcome = NOT_READY
    polls = 0
    herdr.on_start = lambda do |socket, pane, name, kind|
      herdr.put(socket, pane, lambda do
        polls += 1
        keryx('join', name, env: claude(500).merge(in_pane(socket, pane)).tap { alive << 500 }) if polls == 3
        agent(pane, kind, polls < 3 ? 'blocked' : 'working')
      end)
    end
    result = spawn('rev-1', '--harness', 'claude', 'Review it')

    assert_equal 0, result.status, result.err
    assert_equal 1, result.err.scan('shows a dialog').size
    assert_match(/\APane w1:p2 shows a dialog, such as a folder trust or permission question\. Answer it there;/,
                 result.err)
  end

  def test_spawn_gives_up_after_the_timeout_with_status_three
    session_runs
    result = spawn('rev-1', '--harness', 'claude', '--timeout', '5s', 'Review it')
    id = store.unread('rev-1').first.id

    assert_equal 3, result.status
    assert_equal "error: rev-1@athena has not joined yet; look at pane w1:p2; the request #{id} waits in its mailbox\n",
                 result.err
    assert_in_delta 5.0, herdr.starts.first[:timeout]
  end

  def test_a_timeout_behind_a_dialog_says_the_session_joins_once_it_is_answered
    session_runs(screen: "  Hooks need review\n> 1. Review hooks\n")
    result = spawn('impl', '--harness', 'codex', '--timeout', '3s')

    assert_equal 3, result.status
    assert_match(/^Pane w1:p2 shows a dialog/, result.err)
    assert_match(/pane w1:p2 shows a dialog for you to answer, and the session joins by itself once it is answered$/,
                 result.err)
  end

  def test_a_dialog_a_narrow_pane_wraps_is_still_reported
    session_runs(screen: Screens::NARROW_CODEX_HOOKS)
    result = spawn('impl', '--harness', 'codex', '--timeout', '3s')

    assert_equal 3, result.status
    assert_match(/^Pane w1:p2 shows a dialog/, result.err)
  end

  def test_spawn_stops_when_no_session_runs_in_the_pane
    result = spawn('rev-1', '--harness', 'claude')

    assert_equal 1, result.status
    assert_match(/no claude session runs in pane w1:p2, and rev-1@athena has not joined; look at the pane$/, result.err)
  end

  def test_spawn_returns_once_the_session_joins_while_herdr_still_waits
    herdr.start_polls = Float::INFINITY
    polls = 0
    herdr.on_start = lambda do |socket, pane, name, kind|
      herdr.put(socket, pane, lambda do
        polls += 1
        keryx('join', name, env: claude(500).merge(in_pane(socket, pane)).tap { alive << 500 }) if polls == 2
        agent(pane, kind, 'working') if polls > 1
      end)
    end
    result = spawn('rev-1', '--harness', 'claude', '--timeout', '10m')

    assert_equal 0, result.status, result.err
    assert_operator clock.now - NOW, :<=, 2
    assert herdr.starts.first[:starting].stopped
  end

  def test_spawn_stops_when_the_session_leaves_the_pane_before_it_joins
    herdr.start_polls = Float::INFINITY
    polls = 0
    herdr.on_start = lambda do |socket, pane, _name, kind|
      herdr.put(socket, pane, lambda do
        polls += 1
        agent(pane, kind, 'working') if polls == 1
      end)
    end
    result = spawn('rev-1', '--harness', 'claude', '--timeout', '5s')

    assert_equal [1, 1.0], [result.status, clock.now - NOW]
    assert_match(/no claude session runs in pane w1:p2, and rev-1@athena has not joined; look at the pane$/, result.err)
    assert herdr.starts.first[:starting].stopped
  end

  def test_spawn_stops_herdr_when_it_gives_up
    herdr.start_polls = Float::INFINITY
    session_runs
    result = spawn('rev-1', '--harness', 'claude', '--timeout', '3s')

    assert_equal [3, 3.0], [result.status, clock.now - NOW]
    assert herdr.starts.first[:starting].stopped
  end

  def test_a_join_after_the_timeout_is_a_timeout
    herdr.on_start = lambda do |socket, pane, name, kind|
      clock.advance(2)
      herdr.put(socket, pane, agent(pane, kind, 'working'))
      keryx('join', name, env: claude(600).merge(in_pane(socket, pane)).tap { alive << 600 })
    end
    result = spawn('rev-1', '--harness', 'claude', '--timeout', '1s')

    assert_equal 3, result.status
    assert_match(/rev-1@athena joined only after the timeout passed; its session runs in pane w1:p2$/, result.err)
  end

  def test_a_join_less_than_a_second_after_the_timeout_is_a_timeout
    herdr.on_start = lambda do |socket, pane, name, kind|
      clock.advance(1.5)
      herdr.put(socket, pane, agent(pane, kind, 'working'))
      keryx('join', name, env: claude(600).merge(in_pane(socket, pane)).tap { alive << 600 })
    end

    assert_equal 3, spawn('rev-1', '--harness', 'claude', '--timeout', '1s').status
  end

  def test_a_slow_start_still_waits_for_the_join
    herdr.start_outcome = Keryx::Herdr::Outcome.new(ok: false, code: 'timeout', detail: 'timed out waiting')
    session_joins

    assert_equal 0, spawn('rev-1', '--harness', 'claude').status
  end

  def test_a_herdr_start_failure_is_an_error
    herdr.start_outcome = Keryx::Herdr::Outcome.new(ok: false, code: 'pane_busy', detail: 'pane is running a command')
    result = spawn('rev-1', '--harness', 'claude')

    assert_equal 1, result.status
    assert_match(/herdr could not start claude in pane w1:p2: pane_busy: pane is running a command/, result.err)
  end

  def test_another_session_that_joins_the_address_is_a_conflict
    herdr.on_start = lambda do |socket, pane, name, kind|
      herdr.put(socket, pane, agent(pane, kind, 'blocked'))
      alive << 600
      keryx('join', name, env: claude(600).merge(in_pane(socket, 'w9:p9')))
    end
    result = spawn('rev-1', '--harness', 'claude', 'Review it')

    assert_equal 1, result.status
    assert_match(/rev-1@athena was joined by another claude session, not the one spawn started in pane w1:p2/,
                 result.err)
    assert_empty result.out
  end

  def test_a_pane_that_runs_another_harness_is_an_error
    herdr.on_start = ->(socket, pane, _name, _kind) { herdr.put(socket, pane, agent(pane, 'codex', 'idle')) }
    result = spawn('rev-1', '--harness', 'claude')

    assert_equal 1, result.status
    assert_match(/no claude session runs in pane w1:p2/, result.err)
  end

  def test_a_session_that_replaces_a_gone_one_in_the_same_second_joins
    join_claude('rev-1', 111)
    alive.delete(111)
    session_joins

    assert_equal 0, spawn('rev-1', '--harness', 'claude').status
    assert_equal 500, store.occupant('rev-1').pid
  end

  def test_a_session_gone_from_the_address_is_not_taken_for_the_join
    join_claude('rev-1', 111)
    alive.delete(111)
    clock.advance(60)
    session_runs

    assert_equal 3, spawn('rev-1', '--harness', 'claude', '--timeout', '3s').status
  end

  def test_a_gone_session_recorded_in_the_new_pane_is_not_taken_for_the_join
    alive << 111
    keryx('join', 'rev-1', env: claude(111).merge(in_pane(SOCKET, 'w1:p2')))
    alive.delete(111)
    clock.advance(60)
    gone = store.occupant('rev-1')
    session_runs

    assert_equal 3, spawn('rev-1', '--harness', 'claude', '--timeout', '3s').status
    assert_equal gone, store.occupant('rev-1')
  end
end
