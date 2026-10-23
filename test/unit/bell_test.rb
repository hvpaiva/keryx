# frozen_string_literal: true

require 'test_helper'
require 'socket'

class BellTest < Minitest::Test
  include TempDir
  include Factory
  include BellHelpers

  # Each screen with what the bell's detail names of it.
  DIALOGS = {
    'Hooks need review' => '"Hooks need review", line 1 of 1',
    '[a] Trust this workspace' => '"Trust this workspace", line 1 of 1',
    'Held message from another session' => '"Held message", line 1 of 1',
    'Do you want to proceed? (y/n)' => '"Do you want", line 1 of 1',
    Screens::NARROW_CODEX_HOOKS => '"Trust all and continue", line 8 of 20',
    Screens::TINY_CODEX_HOOKS => "\"ente r conf irm \u00b7 esc skip\", line 14 of 20",
    Screens::NARROW_BOX => '"Do you trust", line 1 of 3',
    Screens::WRAPPED_OPTIONS => 'a marked option on line 3 of 4'
  }.freeze

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

  def test_a_pane_where_another_session_of_the_harness_runs_is_absent_and_not_typed_into
    { 'claude' => 'session', 'cursor' => 'conversation' }.each do |harness, label|
      message = deliver
      store.bind('rev-1', pane_occupant(harness:, session_id: 'ended', claude_socket: tmp('gone.sock')))
      herdr = herdr_with('idle', kind: harness, session: 'replacement')

      assert_equal "pane w1:p2 runs #{label} replacement, not ended", bell(herdr:).ring('rev-1', [message]).detail
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

  def test_herdr_types_into_an_idle_or_working_agent
    %w[idle working done].each do |status|
      message = deliver
      store.bind('rev-1', pane_occupant)

      assert_equal 'rung', bell(herdr: herdr_with(status)).ring('rev-1', [message]).status, status
    end
  end

  def test_herdr_types_into_cursor_while_its_follow_ups_box_shows
    message = deliver
    store.bind('rev-1', pane_occupant)
    herdr = herdr_with('working', screen: Screens.session('cursor-follow-ups'))
    result = bell(herdr:).ring('rev-1', [message])

    assert_equal %w[rung herdr], [result.status, result.channel]
    assert_equal 1, herdr.prompts.size
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
    DIALOGS.each do |screen, evidence|
      message = deliver
      store.bind('rev-1', pane_occupant)
      herdr = herdr_with('idle', screen:)

      assert_equal "the screen shows a dialog (#{evidence})", bell(herdr:).ring('rev-1', [message]).detail, screen
      assert_empty herdr.prompts
    end
  end

  def test_a_pane_too_narrow_to_show_a_dialog_defers
    [Screens::TINY_QUESTION, Screens.captured.fetch('cursor-9')].each do |screen|
      message = deliver
      store.bind('rev-1', pane_occupant)
      herdr = herdr_with('idle', screen:)

      assert_equal 'the pane is too narrow to tell whether it shows a dialog',
                   bell(herdr:).ring('rev-1', [message]).detail, screen
      assert_empty herdr.prompts
    end
  end

  def test_every_dialog_captured_from_herdr_counts_at_any_width
    assert_equal 36, Screens.captured.size
    assert_empty(Screens.captured.reject { |_name, screen| Keryx::Bell.obstacle(screen) }.keys)
  end

  def test_an_ordinary_screen_is_no_dialog
    code = "Updated the configuration:\nconst allowOnce = false;\nonEnterConfirm(form);\nTests passed.\n\n> "
    answered = "\u203a yes\n\n\u2022 No problem, I will go on.\n  No other file changes.\n"
    list = "\u203a 1.5 seconds faster\n  2.1 seconds before\n"

    idle = "\u203a Ask Codex to do anything\n\n  gpt-6 low \u00b7 ~/work\n"

    [idle, code, "allowOnce()\nfalse\n> ", answered, list, '> '].each { assert_nil Keryx::Bell.obstacle(it), it }
  end

  def test_herdr_defers_when_the_screen_cannot_be_read
    message = deliver
    store.bind('rev-1', pane_occupant)
    herdr = herdr_with('idle', screen: nil)
    result = bell(herdr:).ring('rev-1', [message])

    assert_equal ['deferred', 'the screen could not be read'], [result.status, result.detail]
    assert_empty herdr.prompts
  end

  def ring_while_the_screen_is_read(herdr, occupant: pane_occupant, &change)
    message = deliver
    store.bind('rev-1', occupant)
    herdr.on_screen = change
    bell(herdr:).ring('rev-1', [message])
  end

  def test_a_session_that_takes_the_pane_while_the_screen_is_read_gets_no_bell
    herdr = herdr_with('idle')
    result = ring_while_the_screen_is_read(herdr) do
      herdr.put(HERDR_SOCKET, 'w1:p2', pane_agent('idle', session: 'replacement'))
    end

    assert_equal ['absent', 'pane w1:p2 runs conversation replacement, not conversation-1'],
                 [result.status, result.detail]
    assert_empty herdr.prompts
  end

  def test_a_process_that_takes_the_pane_while_the_screen_is_read_gets_no_bell
    {
      'pane w1:p2 runs process 501, not 500' => ->(herdr) { herdr.foregrounds[[HERDR_SOCKET, 'w1:p2']] = 501 },
      'process 500 in pane w1:p2 is not the one that joined' => ->(_herdr) { processes.starts[500] = 'started again' }
    }.each do |detail, swap|
      herdr = herdr_with('idle', session: nil)
      occupant = pane_occupant(session_id: nil, **joined_process(herdr))
      result = ring_while_the_screen_is_read(herdr, occupant:) { swap.call(herdr) }

      assert_equal ['absent', detail], [result.status, result.detail]
      assert_empty herdr.prompts
    end
  end

  def test_a_herdr_that_stops_answering_while_the_screen_is_read_defers_the_bell
    herdr = herdr_with('idle')
    result = ring_while_the_screen_is_read(herdr) { herdr.unanswered << [HERDR_SOCKET, 'w1:p2'] }

    assert_equal ['deferred', 'herdr did not answer for pane w1:p2'], [result.status, result.detail]
    assert_empty herdr.prompts
  end

  def test_an_agent_that_turns_blocked_while_the_screen_is_read_defers_the_bell
    herdr = herdr_with('idle')
    result = ring_while_the_screen_is_read(herdr) { herdr.put(HERDR_SOCKET, 'w1:p2', pane_agent('blocked')) }

    assert_equal ['deferred', 'the agent is blocked'], [result.status, result.detail]
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
