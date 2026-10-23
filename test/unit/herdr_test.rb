# frozen_string_literal: true

require 'test_helper'

class HerdrTest < Minitest::Test
  SOCKET = '/run/user/1000/herdr.sock'

  def agent_json(pane, kind, status, session: nil)
    agent = { 'pane_id' => pane, 'agent' => kind, 'agent_status' => status, 'agent_session' => session }.compact
    JSON.generate('result' => { 'agent' => agent })
  end

  def test_agent_reads_kind_and_status_through_the_named_server
    runner = FakeRunner.new(%w[herdr agent get] => { out: agent_json('w1:p2', 'codex', 'idle') })
    agent = Keryx::Herdr.new(runner:).agent(SOCKET, 'w1:p2')

    assert_equal Keryx::Herdr::Agent.new(pane: 'w1:p2', kind: 'codex', status: 'idle'), agent
    assert_equal [%w[herdr agent get w1:p2], { 'HERDR_SOCKET_PATH' => SOCKET }], runner.calls.first
  end

  def test_agent_reads_the_session_id_herdr_was_told
    told = { 'agent' => 'codex', 'kind' => 'id', 'source' => 'herdr:codex', 'value' => 'thread-1' }
    path = told.merge('kind' => 'path', 'value' => '/home/u/.codex/sessions/rollout.jsonl')
    sessions = [told, path, nil].map do |session|
      runner = FakeRunner.new(%w[herdr agent get] => { out: agent_json('w1:p2', 'codex', 'idle', session:) })
      Keryx::Herdr.new(runner:).agent(SOCKET, 'w1:p2').session
    end

    assert_equal ['thread-1', nil, nil], sessions
  end

  def test_agent_is_nil_for_an_empty_pane_or_an_unreachable_server
    missing = { success: false, err: '{"error":{"code":"agent_not_found","message":"not found"}}' }

    assert_nil Keryx::Herdr.new(runner: FakeRunner.new(%w[herdr agent get] => missing)).agent(SOCKET, 'w1:p9')
    assert_nil Keryx::Herdr.new(runner: FakeRunner.new).agent(SOCKET, 'w1:p9')
    assert_nil Keryx::Herdr.new(runner: FakeRunner.new(%w[herdr agent get] => { out: 'garbage' })).agent(SOCKET, 'x')
  end

  def test_agents_lists_every_agent_or_nothing
    list = JSON.generate('result' => { 'agents' => [{ 'pane_id' => 'w1:p1', 'agent' => 'claude',
                                                      'agent_status' => 'working',
                                                      'agent_session' => { 'kind' => 'id', 'value' => 's-1' } }] })

    agents = Keryx::Herdr.new(runner: FakeRunner.new(%w[herdr agent list] => { out: list })).agents(SOCKET)

    assert_equal([%w[claude s-1]], agents.map { [it.kind, it.session] })
    assert_empty Keryx::Herdr.new(runner: FakeRunner.new).agents(SOCKET)
  end

  def test_screen_reads_the_detection_text
    runner = FakeRunner.new(%w[herdr agent read] => { out: "> \n" })

    assert_equal "> \n", Keryx::Herdr.new(runner:).screen(SOCKET, 'w1:p1')
    assert_equal %w[herdr agent read w1:p1 --source detection --lines 20], runner.argvs.first
    assert_nil Keryx::Herdr.new(runner: FakeRunner.new).screen(SOCKET, 'w1:p1')
  end

  def test_footer_reads_the_bottom_lines_of_the_visible_screen
    runner = FakeRunner.new(%w[herdr pane read] => { out: "model 300K\n" })

    assert_equal "model 300K\n", Keryx::Herdr.new(runner:).footer(SOCKET, 'w1:p1')
    assert_equal ['herdr', 'pane', 'read', 'w1:p1', '--source', 'visible', '--lines', '4'],
                 runner.argvs.first
    assert_nil Keryx::Herdr.new(runner: FakeRunner.new).footer(SOCKET, 'w1:p1')
  end

  def test_prompt_reports_herdr_error_codes
    blocked = { success: false, err: '{"error":{"code":"agent_blocked","message":"agent is blocked"}}' }
    outcome = Keryx::Herdr.new(runner: FakeRunner.new(%w[herdr agent prompt] => blocked)).prompt(SOCKET, 'w1:p1', 'hi')

    assert_equal Keryx::Herdr::Outcome.new(ok: false, code: 'agent_blocked', detail: 'agent is blocked'), outcome
    assert Keryx::Herdr.new(runner: FakeRunner.new(%w[herdr agent prompt] => {})).prompt(SOCKET, 'w1:p1', 'hi').ok
  end

  def test_prompt_keeps_a_plain_error_message
    outcome = Keryx::Herdr.new(runner: FakeRunner.new).prompt(SOCKET, 'w1:p1', 'hi')

    assert_nil outcome.code
    assert_equal 'herdr: not found', outcome.detail
  end

  def pane_json(pane, tab, key: 'pane')
    JSON.generate('result' => { key => { 'pane_id' => pane, 'tab_id' => tab,
                                         'workspace_id' => pane.split(':').first } })
  end

  def test_split_opens_a_pane_beside_another_without_taking_the_focus
    runner = FakeRunner.new(%w[herdr pane split] => { out: pane_json('w1:p4', 'w1:t1') })
    pane = Keryx::Herdr.new(runner:).split(SOCKET, 'w1:p1', direction: 'down', cwd: '/work',
                                                            env: { 'KERYX_HOME' => '/state', 'KERYX_HOST' => 'athena' })

    assert_equal Keryx::Herdr::Pane.new(id: 'w1:p4', tab: 'w1:t1', workspace: 'w1'), pane
    assert_equal %w[herdr pane split w1:p1 --direction down --cwd /work --env KERYX_HOME=/state --env KERYX_HOST=athena
                    --no-focus], runner.argvs.first
  end

  def test_create_tab_returns_its_first_pane
    runner = FakeRunner.new(%w[herdr tab create] => { out: pane_json('w1:p5', 'w1:t2', key: 'root_pane') })
    pane = Keryx::Herdr.new(runner:).create_tab(SOCKET, 'w1', label: 'agents', cwd: '/work')

    assert_equal 'w1:t2', pane.tab
    assert_equal %w[herdr tab create --workspace w1 --label agents --cwd /work --no-focus], runner.argvs.first
  end

  def test_pane_tabs_and_panes_read_the_layout_of_a_workspace
    tabs = JSON.generate('result' => { 'tabs' => [{ 'tab_id' => 'w1:t1', 'label' => 'main' }] })
    panes = JSON.generate('result' => { 'panes' => [{ 'pane_id' => 'w1:p1', 'tab_id' => 'w1:t1',
                                                      'workspace_id' => 'w1' }] })
    herdr = Keryx::Herdr.new(runner: FakeRunner.new(%w[herdr pane get] => { out: pane_json('w1:p1', 'w1:t1') },
                                                    %w[herdr tab list] => { out: tabs },
                                                    %w[herdr pane list] => { out: panes }))

    assert_equal 'w1', herdr.pane(SOCKET, 'w1:p1').workspace
    assert_equal [Keryx::Herdr::Tab.new(id: 'w1:t1', label: 'main')], herdr.tabs(SOCKET, 'w1')
    assert_equal ['w1:p1'], herdr.panes(SOCKET, 'w1').map(&:id)
  end

  def test_rename_labels_a_pane_or_says_why_it_could_not
    runner = FakeRunner.new(%w[herdr pane rename w1:p4] => { out: pane_json('w1:p4', 'w1:t1') })
    Keryx::Herdr.new(runner:).rename(SOCKET, 'w1:p4', 'rev-1')
    refused = { success: false, err: '{"error":{"code":"pane_not_found","message":"pane w1:p9 not found"}}' }
    error = assert_raises(Keryx::Error) do
      Keryx::Herdr.new(runner: FakeRunner.new(%w[herdr pane rename] => refused)).rename(SOCKET, 'w1:p9', 'rev-1')
    end

    assert_equal [%w[herdr pane rename w1:p4 rev-1], { 'HERDR_SOCKET_PATH' => SOCKET }], runner.calls.first
    assert_equal 'herdr pane rename failed: pane w1:p9 not found', error.message
  end

  def test_a_failed_control_command_is_an_error_with_what_herdr_said
    refused = { success: false, err: '{"error":{"code":"pane_not_found","message":"pane w1:p9 not found"}}' }
    error = assert_raises(Keryx::Error) do
      Keryx::Herdr.new(runner: FakeRunner.new(%w[herdr pane split] => refused))
                  .split(SOCKET, 'w1:p9', direction: 'right', cwd: '/work')
    end

    assert_equal 'herdr pane split failed: pane w1:p9 not found', error.message
    assert_raises(Keryx::Error) { Keryx::Herdr.new(runner: FakeRunner.new).pane(SOCKET, 'w1:p1') }
  end

  def test_an_answer_without_a_pane_is_an_error
    runner = FakeRunner.new(%w[herdr pane get] => { out: '{"result":{"pane":{}}}' },
                            %w[herdr tab list] => { out: '' })
    herdr = Keryx::Herdr.new(runner:)

    assert_raises(Keryx::Error) { herdr.pane(SOCKET, 'w1:p1') }
    assert_match(/herdr tab list failed: no answer/, assert_raises(Keryx::Error) { herdr.tabs(SOCKET, 'w1') }.message)
  end

  def test_start_names_the_agent_and_passes_its_arguments_after_the_separator
    runner = FakeRunner.new(%w[herdr agent start] => {})
    starting = Keryx::Herdr.new(runner:).start(SOCKET, 'w1:p4', name: 'rev-1', kind: 'claude',
                                                                arguments: ['--model', 'haiku', '--', 'You are rev-1'],
                                                                timeout: 90)

    assert starting.outcome.ok
    assert_equal ['herdr', 'agent', 'start', 'rev-1', '--kind', 'claude', '--pane', 'w1:p4', '--timeout', '90000',
                  '--', '--model', 'haiku', '--', 'You are rev-1'], runner.argvs.first
    assert_equal [{ 'HERDR_SOCKET_PATH' => SOCKET }], runner.calls.map(&:last)
  end

  def test_a_start_still_waiting_has_no_outcome_and_can_be_stopped
    job = Struct.new(:stopped) do
      def done?(**) = false

      def stop = self.stopped = true
    end.new(false)
    starting = Keryx::Herdr::Starting.new(job)

    assert_nil starting.outcome
    starting.stop

    assert job.stopped
  end

  def test_start_keeps_the_timeout_within_what_herdr_accepts
    runner = FakeRunner.new(%w[herdr agent start] => {})
    herdr = Keryx::Herdr.new(runner:)
    herdr.start(SOCKET, 'w1:p4', name: 'a', kind: 'codex', arguments: [], timeout: 1)
    herdr.start(SOCKET, 'w1:p4', name: 'a', kind: 'codex', arguments: [], timeout: 3600)

    assert_equal(%w[3001 300000], runner.argvs.map { it[it.index('--timeout') + 1] })
  end

  def test_start_reports_why_the_agent_is_not_ready
    blocked = { success: false,
                err: '{"error":{"code":"agent_not_ready","message":"agent a is blocked during startup"}}' }
    outcome = Keryx::Herdr.new(runner: FakeRunner.new(%w[herdr agent start] => blocked))
                          .start(SOCKET, 'w1:p4', name: 'a', kind: 'claude', arguments: [], timeout: 60).outcome

    assert_equal Keryx::Herdr::Outcome.new(ok: false, code: 'agent_not_ready',
                                           detail: 'agent a is blocked during startup'), outcome
  end
end
