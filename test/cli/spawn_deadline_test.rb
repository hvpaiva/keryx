# frozen_string_literal: true

require 'test_helper'

class SpawnDeadlineTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers

  def slow(call, seconds = 5)
    herdr.on_call = ->(name) { clock.advance(seconds) if name == call }
  end

  def test_a_split_that_ends_after_the_timeout_leaves_the_pane_with_only_a_shell
    slow(:split)
    result = spawn('rev-1.dev', '--harness', 'claude', '--timeout', '3s', 'Review it')
    id = store.unread('rev-1.dev').first.id

    assert_equal 3, result.status
    assert_equal 'error: the timeout passed after spawn opened pane w1:p2, and it started no claude session there; ' \
                 "the pane holds only a shell, which 'herdr pane close w1:p2' closes; the request #{id} waits in its " \
                 "mailbox\n", result.err
    assert_equal [1, [], nil, []], [herdr.splits.size, herdr.renames, store.spawned('rev-1.dev'), herdr.starts]
  end

  def test_a_label_that_ends_after_the_timeout_records_no_director_and_starts_no_harness
    slow(:rename)
    result = spawn('rev-1.dev', '--harness', 'codex', '--timeout', '3s', 'Review it')

    assert_equal 3, result.status
    assert_match(/\Aerror: the timeout passed after spawn opened pane w1:p2, and it started no codex session there; /,
                 result.err)
    assert_match(/; the request #{store.unread('rev-1.dev').first.id} waits in its mailbox$/, result.err)
    assert_equal [[[SOCKET, 'w1:p2', 'rev-1.dev']], nil, []], [herdr.renames, store.spawned('rev-1.dev'), herdr.starts]
  end

  def test_a_timeout_that_passed_before_the_split_opens_no_pane
    slow(:layout)
    result = spawn('rev-1.dev', '--harness', 'claude', '--timeout', '3s')

    assert_equal 3, result.status
    assert_equal "error: the timeout passed before spawn opened a pane; it started no session for rev-1.dev@athena\n",
                 result.err
    assert_equal [[], [], []], [herdr.splits, herdr.renames, herdr.starts]
  end

  def test_a_timeout_that_passed_before_a_new_tab_opens_no_tab
    workspace(%w[w1:t1 main] => { 'w1:p1' => [120, 48] })
    slow(:layout)
    result = spawn('rev-1.dev', '--harness', 'claude', '--timeout', '3s')

    assert_equal 3, result.status
    assert_match(/before spawn opened a pane; it started no session for rev-1.dev@athena$/, result.err)
    assert_equal [[], []], [herdr.created_tabs, herdr.starts]
  end

  def test_a_herdr_name_freed_after_the_timeout_starts_no_harness
    herdr.put(SOCKET, 'orq_dev', agent('w1:p1', 'claude', 'idle'))
    slow(:clear_name)
    result = spawn('orq.dev', '--harness', 'claude', '--timeout', '3s')

    assert_equal 3, result.status
    assert_match(/after spawn opened pane w1:p2, and it started no claude session there; the pane holds only a shell/,
                 result.err)
    assert_equal [[[SOCKET, 'w1:p1']], []], [herdr.cleared, herdr.starts]
  end

  def test_the_harness_gets_the_time_left_after_a_slow_split
    slow(:split, 2)
    session_joins
    result = spawn('rev-1.dev', '--harness', 'claude', '--timeout', '5s')

    assert_equal 0, result.status, result.err
    assert_in_delta 3.0, herdr.starts.first[:timeout]
  end
end
