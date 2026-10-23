# frozen_string_literal: true

require 'test_helper'

class HerdrControlTest < Minitest::Test
  SOCKET = '/run/user/1000/herdr.sock'

  def agent_json(pane, kind, status, session: nil)
    agent = { 'pane_id' => pane, 'agent' => kind, 'agent_status' => status, 'agent_session' => session }.compact
    JSON.generate('result' => { 'agent' => agent })
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

  # As herdr 0.9.5 answers for a tab that holds one pane.
  LAYOUT = '{"id":"cli:pane:layout","result":{"layout":{"area":{"height":48,"width":205,"x":0,"y":0},' \
           '"focused_pane_id":"wY:p4A","panes":[{"focused":true,"pane_id":"wY:p4A","rect":{"height":48,' \
           '"width":205,"x":0,"y":0}}],"splits":[],"tab_id":"wY:t19","workspace_id":"wY","zoomed":false},' \
           '"type":"pane_layout"}}'

  def test_layout_reads_the_size_of_every_pane_in_the_tab
    runner = FakeRunner.new(%w[herdr pane layout] => { out: LAYOUT })

    assert_equal [Keryx::Herdr::Rect.new(pane: 'wY:p4A', width: 205, height: 48)],
                 Keryx::Herdr.new(runner:).layout(SOCKET, 'wY:p4A')
    assert_equal [%w[herdr pane layout --pane wY:p4A], { 'HERDR_SOCKET_PATH' => SOCKET }], runner.calls.first
  end

  def test_a_layout_herdr_does_not_give_is_an_error_with_its_reason
    refused = { success: false, err: '{"error":{"code":"pane_not_found","message":"pane w1:p9 not found"}}' }
    layouts = ['null', '[]', '{"panes":[]}', '{"panes":{}}', '{"panes":[{"pane_id":"w1:p9"}]}',
               '{"panes":[{"rect":{"width":80,"height":24}}]}',
               '{"panes":[{"pane_id":"w1:p9","rect":{"width":"80","height":24}}]}']
    errors = [refused, *layouts.map { { out: %({"result":{"layout":#{it}}}) } }].map do |answer|
      herdr = Keryx::Herdr.new(runner: FakeRunner.new(%w[herdr pane layout] => answer))
      assert_raises(Keryx::Error) { herdr.layout(SOCKET, 'w1:p9') }.message
    end

    assert_equal ['herdr pane layout failed: pane w1:p9 not found', *['herdr answered without a pane layout'] * 7],
                 errors
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

  def test_clear_name_frees_the_agent_name_a_pane_keeps
    runner = FakeRunner.new(%w[herdr agent rename] => { out: agent_json('w1:p1', 'claude', 'idle') })
    Keryx::Herdr.new(runner:).clear_name(SOCKET, 'w1:p1')
    refused = { success: false, err: '{"error":{"code":"agent_not_found","message":"no agent in pane w1:p9"}}' }
    error = assert_raises(Keryx::Error) do
      Keryx::Herdr.new(runner: FakeRunner.new(%w[herdr agent rename] => refused)).clear_name(SOCKET, 'w1:p9')
    end

    assert_equal [%w[herdr agent rename w1:p1 --clear], { 'HERDR_SOCKET_PATH' => SOCKET }], runner.calls.first
    assert_equal 'herdr agent rename failed: no agent in pane w1:p9', error.message
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
end
