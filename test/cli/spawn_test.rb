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
end
