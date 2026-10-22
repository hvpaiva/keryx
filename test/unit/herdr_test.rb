# frozen_string_literal: true

require 'test_helper'

class HerdrTest < Minitest::Test
  SOCKET = '/run/user/1000/herdr.sock'

  def agent_json(pane, kind, status)
    JSON.generate('result' => { 'agent' => { 'pane_id' => pane, 'agent' => kind, 'agent_status' => status } })
  end

  def test_agent_reads_kind_and_status_through_the_named_server
    runner = FakeRunner.new(%w[herdr agent get] => { out: agent_json('w1:p2', 'codex', 'idle') })
    agent = Keryx::Herdr.new(runner:).agent(SOCKET, 'w1:p2')

    assert_equal Keryx::Herdr::Agent.new(pane: 'w1:p2', kind: 'codex', status: 'idle'), agent
    assert_equal [%w[herdr agent get w1:p2], { 'HERDR_SOCKET_PATH' => SOCKET }], runner.calls.first
  end

  def test_agent_is_nil_for_an_empty_pane_or_an_unreachable_server
    missing = { success: false, err: '{"error":{"code":"agent_not_found","message":"not found"}}' }

    assert_nil Keryx::Herdr.new(runner: FakeRunner.new(%w[herdr agent get] => missing)).agent(SOCKET, 'w1:p9')
    assert_nil Keryx::Herdr.new(runner: FakeRunner.new).agent(SOCKET, 'w1:p9')
    assert_nil Keryx::Herdr.new(runner: FakeRunner.new(%w[herdr agent get] => { out: 'garbage' })).agent(SOCKET, 'x')
  end

  def test_agents_lists_every_agent_or_nothing
    list = JSON.generate('result' => { 'agents' => [{ 'pane_id' => 'w1:p1', 'agent' => 'claude',
                                                      'agent_status' => 'working' }] })

    assert_equal ['claude'], Keryx::Herdr.new(runner: FakeRunner.new(%w[herdr agent list] => { out: list }))
                                         .agents(SOCKET).map(&:kind)
    assert_empty Keryx::Herdr.new(runner: FakeRunner.new).agents(SOCKET)
  end

  def test_screen_reads_the_detection_text
    runner = FakeRunner.new(%w[herdr agent read] => { out: "> \n" })

    assert_equal "> \n", Keryx::Herdr.new(runner:).screen(SOCKET, 'w1:p1')
    assert_equal %w[herdr agent read w1:p1 --source detection --lines 20], runner.argvs.first
    assert_nil Keryx::Herdr.new(runner: FakeRunner.new).screen(SOCKET, 'w1:p1')
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
end
