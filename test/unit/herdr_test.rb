# frozen_string_literal: true

require 'test_helper'

class HerdrTest < Minitest::Test
  SOCKET = '/run/user/1000/herdr.sock'
  WRONG_SHAPES = ['[]', 'true', '7', '"idle"', 'null', '{"result":[]}', '{"result":true}'].freeze
  AGENT = { 'pane_id' => 'w1:p2', 'agent' => 'codex', 'agent_status' => 'idle' }.freeze
  MALFORMED_AGENTS = [true, 7, [], {}, AGENT.merge('pane_id' => 2), AGENT.merge('agent' => nil),
                      AGENT.merge('agent_status' => ['idle']), AGENT.except('agent_status')].freeze

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

  def answering(command, out) = Keryx::Herdr.new(runner: FakeRunner.new(command => { out: }))

  def test_look_takes_an_answer_of_the_wrong_shape_for_no_answer
    answers = WRONG_SHAPES + ['{"result":{"agent":[]}}', '{"result":{"agent":"codex"}}'] +
              MALFORMED_AGENTS.map { JSON.generate('result' => { 'agent' => it }) }
    looks = answers.map { answering(%w[herdr agent get], it).look(SOCKET, 'w1:p2') }

    assert_equal [nil] * answers.size, looks
  end

  def test_look_still_tells_a_pane_herdr_says_is_gone
    gone = %w[agent_not_found pane_not_found].map do |code|
      refused = { success: false, err: JSON.generate('result' => [], 'error' => { 'code' => code }) }
      Keryx::Herdr.new(runner: FakeRunner.new(%w[herdr agent get] => refused)).look(SOCKET, 'w1:p2')
    end

    assert_equal [Keryx::Herdr::NONE] * 2, gone
  end

  def test_an_agent_session_of_the_wrong_shape_is_no_session
    sessions = [{ 'kind' => 'id', 'value' => 7 }, { 'kind' => 'id' }, 'thread-1', %w[id thread-1]].map do |session|
      answering(%w[herdr agent get], JSON.generate('result' => { 'agent' => AGENT.merge('agent_session' => session) }))
        .agent(SOCKET, 'w1:p2')
    end

    assert_equal [Keryx::Herdr::Agent.new(pane: 'w1:p2', kind: 'codex', status: 'idle')] * 4, sessions
  end

  def test_foreground_reads_the_group_only_from_an_answer_of_the_right_shape
    info = ->(value) { JSON.generate('result' => { 'process_info' => { 'foreground_process_group_id' => value } }) }
    wrong = WRONG_SHAPES + ['{"result":{"process_info":[]}}', '{"result":{"process_info":7}}', info.call('500'),
                            info.call(0)]
    foreground = ->(answer) { answering(%w[herdr pane process-info], answer).foreground(SOCKET, 'w1:p2') }

    assert_equal [nil] * wrong.size, wrong.map(&foreground)
    assert_equal 500, foreground.call(info.call(500))
  end

  def test_agents_takes_a_list_of_the_wrong_shape_for_no_agents
    answers = WRONG_SHAPES + ['{"result":{"agents":{}}}', '{"result":{"agents":"w1:p2"}}', '{"result":{"agents":7}}']
    lists = answers.map { answering(%w[herdr agent list], it).agents(SOCKET) }

    assert_equal [[]] * answers.size, lists
  end

  def test_agents_drops_the_records_of_the_wrong_shape_and_keeps_the_rest
    list = JSON.generate('result' => { 'agents' => [*MALFORMED_AGENTS.first(4), AGENT, *MALFORMED_AGENTS.drop(4)] })

    assert_equal [Keryx::Herdr::Agent.new(pane: 'w1:p2', kind: 'codex', status: 'idle')],
                 answering(%w[herdr agent list], list).agents(SOCKET)
  end

  def test_screen_reads_the_detection_text
    runner = FakeRunner.new(%w[herdr agent read] => { out: "> \n" })

    assert_equal "> \n", Keryx::Herdr.new(runner:).screen(SOCKET, 'w1:p1')
    assert_equal %w[herdr agent read w1:p1 --source detection --lines 20], runner.argvs.first
    assert_nil Keryx::Herdr.new(runner: FakeRunner.new).screen(SOCKET, 'w1:p1')
  end

  def test_visible_reads_the_pane_as_a_person_sees_it
    runner = FakeRunner.new(%w[herdr pane read] => { out: "Hooks need review\n" })

    assert_equal "Hooks need review\n", Keryx::Herdr.new(runner:).visible(SOCKET, 'w1:p2')
    assert_equal %w[herdr pane read w1:p2 --source visible --lines 60], runner.argvs.first
    assert_nil Keryx::Herdr.new(runner: FakeRunner.new).visible(SOCKET, 'w1:p2')
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
