# frozen_string_literal: true

require 'test_helper'

class StatusJSONTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  SOCKET = '/h.sock'
  PANE = 'w1:p3'
  # Cursor's workspace trust as herdr shows it at 120 columns.
  TRUST = Screens.captured.fetch('cursor-120')

  def setup
    super
    @orq = join_claude('orq.dev', 111)
  end

  def status_run = keryx('status', '-o', 'json')

  def not_rung = JSON.parse(status_run.out)['not_rung']

  # A Cursor session in a herdr pane, so its bell reads the pane's screen before it types.
  def join_cursor(name)
    herdr.put(SOCKET, PANE, Keryx::Herdr::Agent.new(pane: PANE, kind: 'cursor', status: 'idle', session: 'conv-1'))
    keryx('join', name, env: { 'CURSOR_CONVERSATION_ID' => 'conv-1', 'HERDR_SOCKET_PATH' => SOCKET,
                               'HERDR_PANE_ID' => PANE })
  end

  def deferred_by_trust
    join_cursor('impl.dev')
    herdr.show(SOCKET, PANE, TRUST)
    keryx('send', 'impl.dev', 'hello', env: @orq)
  end

  def test_a_bell_a_trust_dialog_kept_from_typing_gives_its_obstacle_channel_time_and_evidence
    deferred_by_trust
    record = not_rung.first

    assert_equal({ 'bell' => 'deferred', 'detail' => 'the screen shows a dialog ("Do you trust", line 9 of 20)',
                   'obstacle' => 'dialog', 'channel' => 'herdr', 'at' => clock.now.utc.iso8601,
                   'evidence' => 'Do you trust' }, record.except('id', 'to', 'from'))
    assert_operator record['evidence'].size, :<=, 60
    assert_empty herdr.prompts
  end

  def test_a_bell_receipt_written_without_obstacle_and_evidence_gives_null_for_them
    deferred_by_trust
    id = not_rung.first['id']
    path = tmp('state', 'addresses', 'impl.dev', 'receipts', "#{id}.bell")
    File.write(path, JSON.generate(JSON.parse(File.read(path)).except('obstacle', 'evidence')))
    run = status_run

    assert_equal ['deferred', 'herdr', clock.now.utc.iso8601, nil, nil],
                 JSON.parse(run.out)['not_rung'].first.values_at('bell', 'channel', 'at', 'obstacle', 'evidence')
    assert_empty run.err
  end

  def test_a_message_never_rung_gives_null_for_the_four
    keryx('send', 'orq.dev', 'a note to self', env: @orq)

    assert_equal([['none', 'never rung', nil, nil, nil, nil]],
                 not_rung.map { it.values_at('bell', 'detail', 'obstacle', 'channel', 'at', 'evidence') })
  end
end
