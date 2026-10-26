# frozen_string_literal: true

require 'test_helper'

class ReservedScopeTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers

  RESERVED = 'is in a reserved scope: NAME.local is a person at a terminal, which acts as it without joining, ' \
             "and keryx.system is keryx's own services\n"
  AS_PERSON = 'error: an agent session cannot act as person.local@athena, a person at a terminal; a plain ' \
              "terminal acts as it with no --as\n"
  AS_SYSTEM = "error: an agent session cannot act as keryx.system@athena, keryx's own services\n"
  # What the page passes to keryx, with base_env's USER and KERYX_HOST taken out and the host read from the config.
  PAGE = { 'USER' => nil, 'KERYX_HOST' => nil, 'PATH' => '/usr/bin:/bin', 'LANG' => 'C.UTF-8',
           'NO_COLOR' => '1' }.freeze

  def outcome(*argv, env:)
    result = keryx(*argv, env:)
    [result.status, result.err]
  end

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

  def test_an_agent_session_cannot_act_as_a_reserved_address_with_as_or_keryx_as
    rev = join_claude('rev-1.dev', 111)
    keryx('ask', 'person.local', 'Approve the release?', env: rev)
    id = store.unread('person.local').first.id
    [%w[send rev-1.dev approved], ['read', id], %w[inbox], ['reply', id, 'approved'], %w[whoami]].each do |argv|
      assert_equal [1, AS_PERSON], outcome('--as', 'person.local', *argv, env: rev), argv
      assert_equal [1, AS_SYSTEM], outcome('--as', 'keryx.system', *argv, env: rev), argv
    end
    [%w[send rev-1.dev approved], %w[inbox]].each do |argv|
      assert_equal [1, AS_PERSON], outcome(*argv, env: rev.merge('KERYX_AS' => 'person.local')), argv
    end

    assert_equal [id], store.unread('person.local').map(&:id)
    assert_empty store.unread('rev-1.dev')
  end

  def test_the_refusal_names_the_way_out_for_this_terminals_address_and_for_another_persons
    rev = join_claude('rev-1.dev', 111).merge('USER' => 'person')
    other = 'error: an agent session cannot act as other.local@athena, a person at a terminal; only a plain ' \
            "terminal acts as it, with --as\n"

    assert_equal [1, AS_PERSON], outcome('--as', 'person.local', 'whoami', env: rev)
    assert_equal [1, other], outcome('--as', 'other.local', 'whoami', env: rev)
  end

  def test_an_agent_herdr_reports_in_a_pane_without_harness_variables_is_refused_too
    store.create_address('person.local', role: 'human')
    herdr.put(SOCKET, 'w1:p1', agent('w1:p1', 'claude', 'idle'))

    assert_equal [1, AS_PERSON], outcome('--as', 'person.local', 'inbox', env: CALLER)
    assert_equal [1, AS_PERSON],
                 outcome('--as', 'person.local', 'spawn', 'rev-1.dev', '--harness', 'claude', 'Review it', env: CALLER)
    assert_empty herdr.splits
  end

  def test_a_plain_terminal_and_the_page_act_as_the_person_and_mark_the_mail_read
    rev = join_claude('rev-1.dev', 111)
    write_config("host = athena\n")
    keryx('ask', 'person.local', 'Approve the release?', env: rev)
    clock.advance(1)
    keryx('send', 'person.local', 'A note', env: rev)
    request, note = store.unread('person.local').map(&:id)

    assert_equal 0, keryx('--as', 'person.local', 'read', request).status
    assert_equal 0, keryx('--as', 'person.local@athena', 'reply', request, 'approved', env: PAGE).status
    assert_equal 0, keryx('--as', 'person.local@athena', 'read', note, env: PAGE).status
    assert_empty store.unread('person.local')
    assert_equal ['person.local@athena'], store.unread('rev-1.dev').map(&:from)
  end

  def test_the_launcher_in_a_pane_herdr_reports_no_agent_in_spawns_as_the_person
    store.create_address('person.local', role: 'human')
    session_joins
    result = keryx('--as', 'person.local', 'spawn', 'rev-1.dev', '--harness', 'claude', 'Review it', env: CALLER)

    assert_equal 0, result.status, result.err
    assert_equal ['person.local@athena'], store.unread('rev-1.dev').map(&:from)
  end
end
