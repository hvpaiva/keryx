# frozen_string_literal: true

require 'test_helper'

class IdentityTest < Minitest::Test
  include TempDir
  include Factory

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def claude_caller(pid: 4242)
    Keryx::Caller.new(harness: 'claude', session_id: "session-#{pid}", pid:, claude_socket: nil, herdr_socket: nil,
                      herdr_pane: nil, cwd: '/work')
  end

  def terminal_caller
    Keryx::Caller.new(harness: nil, session_id: nil, pid: nil, claude_socket: nil, herdr_socket: nil,
                      herdr_pane: nil, cwd: '/work')
  end

  def identity(caller, env = { 'USER' => 'hvpaiva' }) = Keryx::Identity.new(store:, caller:, env:)

  def test_an_agent_acts_as_the_address_it_joined
    store.create_address('rev-1')
    store.bind('rev-1', claude_caller.occupant(NOW))

    assert_equal 'rev-1', identity(claude_caller).current
    assert_equal 'rev-1', identity(claude_caller).held
  end

  def test_an_agent_that_joined_nothing_is_refused
    error = assert_raises(Keryx::Error) { identity(claude_caller).current }

    assert_match(/claude session holds no address; run 'keryx join NAME'/, error.message)
    assert_empty store.address_names
  end

  def test_a_person_acts_as_an_address_named_after_user
    assert_equal 'hvpaiva', identity(terminal_caller).current
    assert_equal 'human', store.address('hvpaiva').role
  end

  def test_the_human_name_is_made_valid
    assert_equal 'j-doe', identity(terminal_caller, { 'USER' => 'J.Doe' }).human_name
    assert_equal 'human', identity(terminal_caller, { 'USER' => '1234' }).human_name
    assert_equal 'human', identity(terminal_caller, {}).human_name
  end

  def test_as_names_an_existing_address
    store.create_address('orq')

    assert_equal 'orq', identity(claude_caller).current(as: 'orq')
    assert_match(/no address ghost/, assert_raises(Keryx::Error) { identity(terminal_caller).current(as: 'ghost') }
                                       .message)
  end

  def test_another_session_does_not_inherit_the_address
    store.create_address('rev-1')
    store.bind('rev-1', claude_caller.occupant(NOW))

    assert_nil identity(claude_caller(pid: 7)).held
  end

  def test_an_occupant_that_cannot_be_read_is_passed_over_and_reported
    store.create_address('broken')
    path = tmp('state', 'addresses', 'broken', 'occupant.json')
    File.write(path, JSON.generate(claude_caller.occupant(NOW).record.merge('pid' => [])))
    store.create_address('rev-1')
    store.bind('rev-1', claude_caller.occupant(NOW))

    assert_equal 'rev-1', identity(claude_caller).held
    assert_equal ["#{path} is damaged"], store.problems
  end
end
