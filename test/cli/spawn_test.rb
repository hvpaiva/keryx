# frozen_string_literal: true

require 'test_helper'

class SpawnTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers

  def test_spawn_starts_the_harness_beside_this_pane_and_waits_for_the_join
    session_joins
    result = spawn('rev-1', '--harness', 'claude', '--role', 'reviewer', 'Review PR #448')
    id = store.unread('rev-1').first.id

    assert_equal 0, result.status, result.err
    assert_equal "Spawned rev-1@athena as a claude session in pane w1:p2, and it joined.\n" \
                 "Its first request is #{id}.\n" \
                 "'keryx inbox' shows the reply when it arrives; 'keryx wait #{id}' blocks until then.\n", result.out
    assert_equal [['w1:p1', 'right', '/work', session_env]], herdr.splits
    assert_equal ['reviewer', 'person@athena', 'Review PR #448'],
                 [store.address('rev-1').role, store.unread('rev-1').first.from, store.unread('rev-1').first.body]
  end

  def test_claude_starts_named_with_the_keryx_settings_and_the_first_prompt_last
    session_joins
    spawn('rev-1', '--harness', 'claude', '--role', 'code reviewer', '--model', 'haiku', '--prompt',
          "Focus on\nretries\e[2J", 'Review it', '--', '--add-dir', '../site')
    start = herdr.starts.first

    assert_equal %w[rev-1 claude w1:p2], start.values_at(:name, :kind, :pane)
    assert_equal ['-n', 'rev-1', '--remote-control', 'rev-1', '--model', 'haiku', '--settings',
                  Keryx::Harness::CLAUDE_SETTINGS, '--add-dir', '../site', '--'], start[:arguments][0...-1]
    assert_equal "You are rev-1@athena, the code reviewer, started by keryx spawn. Run 'keryx join rev-1 --role " \
                 "code\\ reviewer', then run 'keryx skill' and follow it, then run 'keryx inbox'. Focus on " \
                 'retries^[[2J', start[:arguments].last
    assert_equal 'Review it', store.unread('rev-1').first.body
  end

  def test_codex_gets_the_store_through_its_config
    session_joins
    result = spawn('impl', '--harness', 'codex', '--effort', 'low')

    assert_equal "Spawned impl@athena as a codex session in pane w1:p2, and it joined.\n", result.out
    assert_equal ['-c', 'model_reasoning_effort="low"',
                  '-c', %(shell_environment_policy.set.KERYX_HOME="#{tmp('state')}"),
                  '-c', 'shell_environment_policy.set.KERYX_HOST="athena"',
                  '-c', %(shell_environment_policy.set.HERDR_SOCKET_PATH="#{SOCKET}"),
                  '-c', 'shell_environment_policy.set.HERDR_PANE_ID="w1:p2"', '--',
                  "You are impl@athena, started by keryx spawn. Run 'keryx join impl', then run 'keryx skill' and " \
                  "follow it, then run 'keryx inbox'."], herdr.starts.first[:arguments]
    assert_empty store.mailbox('impl')
  end

  def test_the_request_waits_in_the_mailbox_before_the_session_starts
    seen = nil
    herdr.on_start = ->(*) { seen = store.unread('impl').map { [it.body, it.due_at] } }
    result = spawn('impl', '--harness', 'codex', '--file', '-', '--within', '30m', input: "Implement retries\n")

    assert_equal [["Implement retries\n", NOW + 1800]], seen
    assert_match(/the request #{store.unread('impl').first.id} waits in its mailbox$/, result.err)
  end

  def test_an_agent_learns_that_the_reply_will_ring_it
    session_joins
    orq = join_claude('orq', 111)
    result = spawn('rev-1', '--harness', 'claude', 'Review it', env: orq)

    assert_match(/^The reply will ring this session;/, result.out)
    assert_equal 'orq@athena', store.unread('rev-1').first.from
  end

  def test_tab_is_created_when_missing_and_split_once_it_exists
    session_joins(pid: 500)
    spawn('rev-1', '--harness', 'claude', '--tab', 'agents')

    assert_equal [['w1', 'agents', '/work', session_env]], herdr.created_tabs
    assert_equal 'w1:p2', herdr.starts.last[:pane]

    session_joins(pid: 600)
    spawn('rev-2', '--harness', 'claude', '--tab', 'agents', '--split', 'down')

    assert_equal [['w1:p2', 'down', '/work', session_env]], herdr.splits
    assert_equal 'w1:p3', herdr.starts.last[:pane]
  end

  def test_the_directory_and_the_store_reach_the_new_pane
    session_joins
    spawn('rev-1', '--harness', 'claude', '--cwd', tmp, env: { 'KERYX_HOST' => '' })

    assert_equal [tmp, { 'KERYX_HOME' => tmp('state') }], herdr.splits.first[2..]
  end

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
