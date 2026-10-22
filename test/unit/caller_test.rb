# frozen_string_literal: true

require 'test_helper'

class CallerTest < Minitest::Test
  include Factory

  HERDR_SOCKET = '/run/user/1000/herdr.sock'
  CLAUDE_ENV = {
    'CLAUDECODE' => '1', 'CLAUDE_CODE_SESSION_ID' => 'session-1', 'CLAUDE_PID' => '4242',
    'CLAUDE_CODE_MESSAGING_SOCKET' => '/run/user/1000/cc-socks/4242.sock',
    'HERDR_SOCKET_PATH' => HERDR_SOCKET, 'HERDR_PANE_ID' => 'w1:p1'
  }.freeze

  def caller_from(env, herdr: FakeHerdr.new) = Keryx::Caller.from_env(env, cwd: '/work', herdr:)

  def test_a_claude_session_is_read_from_its_own_variables
    caller = caller_from(CLAUDE_ENV)

    assert_equal 'claude', caller.harness
    assert_equal 4242, caller.pid
    assert_equal '/run/user/1000/cc-socks/4242.sock', caller.claude_socket
    assert_equal 'w1:p1', caller.herdr_pane
  end

  def test_another_harness_is_named_by_herdr
    herdr = FakeHerdr.new({ [HERDR_SOCKET, 'w1:p2'] => Keryx::Herdr::Agent.new('w1:p2', 'codex', 'working') })
    caller = caller_from({ 'HERDR_SOCKET_PATH' => HERDR_SOCKET, 'HERDR_PANE_ID' => 'w1:p2' }, herdr:)

    assert_equal 'codex', caller.harness
    assert_nil caller.pid
    assert_predicate caller, :agent?
  end

  def test_a_codex_session_is_named_by_its_thread
    caller = caller_from({ 'CODEX_THREAD_ID' => 'thread-1' })

    assert_equal %w[codex thread-1], [caller.harness, caller.session_id]
    assert caller.holds?(build_occupant(harness: 'codex', session_id: 'thread-1'))
  end

  def test_a_cursor_session_is_named_by_its_conversation
    caller = caller_from({ 'CURSOR_CONVERSATION_ID' => 'conversation-1' })

    assert_equal %w[cursor conversation-1], [caller.harness, caller.session_id]
    assert caller.holds?(build_occupant(harness: 'cursor', session_id: 'conversation-1'))
  end

  def test_a_harness_started_from_claude_code_is_not_taken_for_it
    cursor = caller_from(CLAUDE_ENV.merge('CURSOR_CONVERSATION_ID' => 'conversation-1'))
    codex = caller_from(CLAUDE_ENV.merge('CODEX_THREAD_ID' => 'thread-1'))

    assert_equal([%w[cursor conversation-1], %w[codex thread-1]], [cursor, codex].map { [it.harness, it.session_id] })
    assert_equal [nil, nil], [cursor.pid, codex.claude_socket]
    refute cursor.holds?(build_occupant(pid: 4242, session_id: 'session-1'))
  end

  def test_a_plain_terminal_is_not_an_agent
    refute_predicate caller_from({}), :agent?
    refute_predicate caller_from({ 'HERDR_SOCKET_PATH' => HERDR_SOCKET, 'HERDR_PANE_ID' => 'w1:p3' }), :agent?
  end

  def test_claude_variables_without_claudecode_are_ignored
    caller = caller_from(CLAUDE_ENV.merge('CLAUDECODE' => ''))

    assert_nil caller.pid
    assert_nil caller.claude_socket
  end

  def test_it_holds_an_address_through_its_process_or_session
    caller = caller_from(CLAUDE_ENV)

    assert caller.holds?(build_occupant(pid: 4242, session_id: 'other'))
    assert caller.holds?(build_occupant(pid: 1, session_id: 'session-1'))
    refute caller.holds?(build_occupant(pid: 1, session_id: 'other'))
  end

  def test_the_pane_keeps_an_address_only_for_the_same_harness
    herdr = FakeHerdr.new({ [HERDR_SOCKET, 'w1:p2'] => Keryx::Herdr::Agent.new('w1:p2', 'codex', 'idle') })
    caller = caller_from({ 'HERDR_SOCKET_PATH' => HERDR_SOCKET, 'HERDR_PANE_ID' => 'w1:p2' }, herdr:)
    pane = { herdr_socket: HERDR_SOCKET, herdr_pane: 'w1:p2', pid: nil, session_id: nil }

    assert caller.holds?(build_occupant(harness: 'codex', **pane))
    refute caller.holds?(build_occupant(harness: 'claude', **pane))
    refute caller.holds?(build_occupant(harness: 'codex', **pane, herdr_socket: '/other.sock'))
  end

  def test_occupant_copies_what_identifies_the_session
    occupant = caller_from(CLAUDE_ENV).occupant(NOW)

    assert_equal %w[claude session-1 4242 w1:p1 /work],
                 [occupant.harness, occupant.session_id, occupant.pid.to_s, occupant.herdr_pane, occupant.cwd]
    assert_equal NOW, occupant.joined_at
  end
end
