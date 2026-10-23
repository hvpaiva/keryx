# frozen_string_literal: true

require 'test_helper'
require 'socket'

class BellTest < Minitest::Test
  include TempDir
  include Factory

  HERDR_SOCKET = '/run/user/1000/herdr.sock'

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def queue = @queue ||= CLIHelpers::FakeCodexQueue.new

  def bell(herdr: FakeHerdr.new, claude_socket: Keryx::Bell::ClaudeSocket.new)
    Keryx::Bell.new(store:, herdr:, clock: -> { NOW }, claude_socket:, codex: queue)
  end

  def deliver(kind: 'request')
    store.create_address('rev-1')
    build_message(to: 'rev-1@athena', kind:).tap { store.deliver('rev-1', it) }
  end

  def pane_occupant(**overrides)
    build_occupant(harness: 'codex', session_id: nil, herdr_socket: HERDR_SOCKET, herdr_pane: 'w1:p2', **overrides)
  end

  def herdr_with(status, screen: '> ', outcome: Keryx::Herdr::Outcome.new(ok: true, code: nil, detail: nil),
                 session: nil, kind: 'codex')
    agent = Keryx::Herdr::Agent.new(pane: 'w1:p2', kind:, status:, session:)
    screens = { [HERDR_SOCKET, 'w1:p2'] => screen }
    FakeHerdr.new({ [HERDR_SOCKET, 'w1:p2'] => agent }, screens:, prompt_outcome: outcome)
  end

  def with_claude_socket
    path = tmp('cc.sock')
    server = UNIXServer.new(path)
    received = Thread.new { server.accept.then { |client| client.read.tap { client.close } } }
    yield path
    received.value
  ensure
    server&.close
  end

  def test_a_claude_session_is_rung_through_its_peer_socket
    message = deliver
    line = with_claude_socket do |path|
      store.bind('rev-1', build_occupant(claude_socket: path))

      assert_equal 'rung', bell.ring('rev-1', [message]).status
    end
    frame = JSON.parse(line)

    assert_equal 'user', frame['type']
    assert_match(/\A\[keryx\] New request for rev-1@athena from orq@athena \(#{message.id}\)\./,
                 frame.dig('message', 'content'))
  end

  def test_the_bell_never_carries_the_body
    message = deliver
    line = with_claude_socket do |path|
      store.bind('rev-1', build_occupant(claude_socket: path))
      bell.ring('rev-1', [message])
    end

    refute_includes line, message.body
  end

  def test_the_result_is_recorded_against_every_message
    first = deliver
    second = build_message(to: 'rev-1@athena').tap { store.deliver('rev-1', it) }
    result = bell.ring('rev-1', [first, second])

    assert_equal 'absent', result.status
    assert_equal result.record, store.receipt('rev-1', first.id, 'bell')
    assert_equal result.record, store.receipt('rev-1', second.id, 'bell')
  end

  def test_a_dead_claude_socket_falls_back_to_the_herdr_pane
    message = deliver
    store.bind('rev-1', pane_occupant(harness: 'claude', claude_socket: tmp('gone.sock')))
    herdr = herdr_with('idle', kind: 'claude')
    result = bell(herdr:).ring('rev-1', [message])

    assert_equal %w[rung herdr], [result.status, result.channel]
    assert_equal 1, herdr.prompts.size
  end

  def test_a_pane_that_runs_another_harness_is_absent_and_not_typed_into
    [%w[claude codex], %w[cursor claude], %w[codex cursor]].each do |harness, running|
      message = deliver
      store.bind('rev-1', pane_occupant(harness:, claude_socket: (tmp('gone.sock') if harness == 'claude')))
      herdr = herdr_with('idle', kind: running)
      result = bell(herdr:).ring('rev-1', [message])

      assert_equal ['absent', "pane w1:p2 runs #{running}, not #{harness}"], [result.status, result.detail]
      assert_empty herdr.prompts
    end
  end

  def test_a_dead_claude_socket_without_a_pane_fails
    message = deliver
    store.bind('rev-1', build_occupant(claude_socket: tmp('gone.sock')))
    result = bell.ring('rev-1', [message])

    assert_equal %w[failed claude], [result.status, result.channel]
    assert_match(/gone.sock/, result.detail)
  end

  def test_a_codex_thread_herdr_shows_open_in_its_pane_is_rung_through_its_queue
    message = deliver
    store.bind('rev-1', pane_occupant(session_id: 'thread-1'))
    herdr = herdr_with('working', session: 'thread-1')
    result = bell(herdr:).ring('rev-1', [message])

    assert_equal %w[rung codex], [result.status, result.channel]
    assert_equal 'thread-1', queue.queued.first.first
    assert_match(/\A\[keryx\] New request for rev-1@athena/, queue.queued.first.last)
    assert_empty herdr.prompts
  end

  def test_a_codex_thread_closed_in_its_pane_is_absent_and_never_queued
    message = deliver
    store.bind('rev-1', pane_occupant(session_id: 'thread-1'))
    result = bell.ring('rev-1', [message])

    assert_equal ['absent', 'thread thread-1 is not open in a herdr pane'], [result.status, result.detail]
    assert_empty queue.queued
  end

  def test_a_codex_thread_without_a_pane_is_absent_and_never_queued
    message = deliver
    store.bind('rev-1', build_occupant(harness: 'codex', session_id: 'thread-1'))
    result = bell.ring('rev-1', [message])

    assert_equal ['absent', 'thread thread-1 is not open in a herdr pane'], [result.status, result.detail]
    assert_empty queue.queued
  end

  def test_a_codex_pane_that_reports_no_session_is_typed_and_never_queued
    message = deliver
    store.bind('rev-1', pane_occupant(session_id: 'thread-1'))
    herdr = herdr_with('idle')
    result = bell(herdr:).ring('rev-1', [message])

    assert_equal %w[rung herdr], [result.status, result.channel]
    assert_equal 1, herdr.prompts.size
    assert_empty queue.queued
  end

  def test_a_codex_pane_running_another_thread_is_absent_and_neither_typed_nor_queued
    message = deliver
    store.bind('rev-1', pane_occupant(session_id: 'thread-1'))
    herdr = herdr_with('idle', session: 'thread-2')
    result = bell(herdr:).ring('rev-1', [message])

    assert_equal ['absent', 'pane w1:p2 runs thread thread-2, not thread-1'], [result.status, result.detail]
    assert_empty herdr.prompts
    assert_empty queue.queued
  end

  def test_an_open_codex_thread_whose_queue_fails_is_typed_into_its_pane
    message = deliver
    queue.gone << 'thread-1'
    store.bind('rev-1', pane_occupant(session_id: 'thread-1'))
    herdr = herdr_with('idle', session: 'thread-1')
    result = bell(herdr:).ring('rev-1', [message])

    assert_equal %w[rung herdr], [result.status, result.channel]
    assert_equal 1, herdr.prompts.size
  end

  def test_herdr_types_into_an_idle_or_working_agent
    %w[idle working done].each do |status|
      message = deliver
      store.bind('rev-1', pane_occupant)

      assert_equal 'rung', bell(herdr: herdr_with(status)).ring('rev-1', [message]).status, status
    end
  end

  def test_herdr_defers_while_the_agent_is_blocked_or_unknown
    %w[blocked unknown].each do |status|
      message = deliver
      store.bind('rev-1', pane_occupant)
      herdr = herdr_with(status)
      result = bell(herdr:).ring('rev-1', [message])

      assert_equal 'deferred', result.status
      assert_empty herdr.prompts
    end
  end

  def test_herdr_defers_when_the_screen_shows_a_dialog
    ['Hooks need review', '[a] Trust this workspace', 'Held message from another session',
     'Do you want to proceed? (y/n)', Screens::NARROW_CODEX_HOOKS, Screens::TINY_CODEX_HOOKS, Screens::NARROW_BOX]
      .each do |screen|
        message = deliver
        store.bind('rev-1', pane_occupant)
        herdr = herdr_with('idle', screen:)

        assert_equal 'the screen shows a dialog', bell(herdr:).ring('rev-1', [message]).detail, screen
        assert_empty herdr.prompts
      end
  end

  def test_an_ordinary_screen_is_no_dialog
    refute Keryx::Bell.dialog?("\u203a Ask Codex to do anything\n\n  gpt-6 low \u00b7 ~/work\n")
  end

  def test_herdr_defers_when_the_screen_cannot_be_read
    message = deliver
    store.bind('rev-1', pane_occupant)
    herdr = herdr_with('idle', screen: nil)
    result = bell(herdr:).ring('rev-1', [message])

    assert_equal ['deferred', 'the screen could not be read'], [result.status, result.detail]
    assert_empty herdr.prompts
  end

  def test_herdr_reports_a_refused_prompt
    message = deliver
    store.bind('rev-1', pane_occupant)
    blocked = Keryx::Herdr::Outcome.new(ok: false, code: 'agent_blocked', detail: 'blocked')
    stalled = Keryx::Herdr::Outcome.new(ok: false, code: 'timeout', detail: 'no answer')

    assert_equal 'deferred', bell(herdr: herdr_with('idle', outcome: blocked)).ring('rev-1', [message]).status
    assert_equal 'timeout: no answer', bell(herdr: herdr_with('idle', outcome: stalled)).ring('rev-1', [message]).detail
  end

  def test_an_empty_pane_is_absent
    message = deliver
    store.bind('rev-1', pane_occupant)
    result = bell.ring('rev-1', [message])

    assert_equal ['absent', 'no agent runs in pane w1:p2'], [result.status, result.detail]
  end

  def test_an_occupant_with_no_channel_is_absent
    message = deliver
    store.bind('rev-1', build_occupant)

    assert_equal 'absent', bell.ring('rev-1', [message]).status
  end

  def test_several_messages_ring_once_with_a_count
    store.create_address('rev-1')
    messages = Array.new(3) { build_message(to: 'rev-1@athena').tap { store.deliver('rev-1', it) } }
    store.bind('rev-1', pane_occupant)
    herdr = herdr_with('idle')
    bell(herdr:).ring('rev-1', messages)

    assert_equal 1, herdr.prompts.size
    assert_match(/\A\[keryx\] 3 unread messages for rev-1@athena/, herdr.prompts.first.last)
  end
end
