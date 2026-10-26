# frozen_string_literal: true

require 'test_helper'

class ReservedScopeTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers

  RESERVED = 'is in a reserved scope: NAME.local is a person at a terminal, which acts as it without joining, ' \
             "and keryx.system is keryx's own services\n"

  def test_join_refuses_an_agent_every_reserved_address_the_persons_own_included
    alive << 111
    { 'person.local' => 'person.local@athena', 'person.local@athena' => 'person.local@athena',
      'other.local' => 'other.local@athena', 'keryx.system' => 'keryx.system@athena' }.each do |name, full|
      result = keryx('join', name, env: claude(111))

      assert_equal [1, "error: #{full} #{RESERVED}"], [result.status, result.err], name
    end
    assert_empty store.address_names
  end

  def test_spawn_refuses_a_reserved_address_before_it_opens_a_pane
    result = spawn('person.local', '--harness', 'claude', 'Answer for me')

    assert_equal [1, "error: person.local@athena #{RESERVED}"], [result.status, result.err]
    assert_empty herdr.splits
    refute store.address?('person.local')
  end

  def test_a_session_an_older_keryx_bound_to_a_local_address_acts_as_nothing_until_it_joins_a_team
    alive << 111
    store.create_address('orq.dev')
    store.create_address('person.local', role: 'human')
    store.bind('person.local', build_occupant(session_id: 'session-111', pid: 111))
    sent = keryx('send', 'orq.dev', 'as the person', env: claude(111))

    assert_equal [1, "error: this claude session holds no address; run 'keryx join MEMBER.TEAM' in it first\n"],
                 [sent.status, sent.err]
    assert_empty store.unread('orq.dev')
    assert_equal 0, keryx('join', 'rev-1.dev', env: claude(111)).status
    assert_nil store.occupant('person.local')
    assert_equal 111, store.occupant('rev-1.dev').pid
  end
end
