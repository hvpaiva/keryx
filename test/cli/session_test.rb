# frozen_string_literal: true

require 'test_helper'

class SessionTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def test_join_binds_the_claude_session_and_creates_the_address
    alive << 111
    result = keryx('join', 'rev-1', '--role', 'reviewer', env: claude(111))

    assert_equal 0, result.status
    assert_equal "Joined rev-1@athena as a claude session (pid 111).\n", result.out
    assert_equal 'reviewer', store.address('rev-1').role
    assert_equal '/tmp/cc-111.sock', store.occupant('rev-1').claude_socket
  end

  def test_join_refuses_a_role_that_is_not_plain_words
    alive << 111
    result = keryx('join', 'rev-1', '--role', "rev\e[2J", env: claude(111))

    assert_equal 2, result.status
    assert_match(/invalid role/, result.err)
    refute store.address?('rev-1')
  end

  def test_listings_neutralize_escapes_written_into_the_store
    join_claude('rev-1', 111)
    File.write(tmp('state', 'addresses', 'rev-1', 'address.json'),
               JSON.generate('name' => 'rev-1', 'role' => "x\e[2Jy", 'created_at' => NOW.iso8601))

    assert_includes keryx('who').out, 'x^[[2Jy'
    refute_includes keryx('who').out, "\e"
  end

  def test_join_from_a_plain_terminal_is_refused
    result = keryx('join', 'rev-1')

    assert_equal 1, result.status
    assert_match(/join binds the agent session that runs it/, result.err)
  end

  def test_join_in_a_herdr_pane_records_the_harness_herdr_sees
    @herdr = FakeHerdr.new({ ['/h.sock', 'w1:p2'] => Keryx::Herdr::Agent.new('w1:p2', 'codex', 'idle') })
    result = keryx('join', 'impl', env: { 'HERDR_SOCKET_PATH' => '/h.sock', 'HERDR_PANE_ID' => 'w1:p2' })

    assert_equal "Joined impl@athena as a codex session (pane w1:p2).\n", result.out
    assert_equal(%w[codex /h.sock w1:p2], store.occupant('impl').then { [it.harness, it.herdr_socket, it.herdr_pane] })
  end

  def test_join_in_codex_records_its_thread
    result = keryx('join', 'impl', env: { 'CODEX_THREAD_ID' => 'thread-1' })

    assert_equal "Joined impl@athena as a codex session (thread thread-1).\n", result.out
    assert_equal(%w[codex thread-1], store.occupant('impl').then { [it.harness, it.session_id] })
  end

  def test_join_in_cursor_records_its_conversation
    result = keryx('join', 'audit', env: { 'CURSOR_CONVERSATION_ID' => 'conversation-1' })

    assert_equal "Joined audit@athena as a cursor session (conversation conversation-1).\n", result.out
    assert_equal(%w[cursor conversation-1], store.occupant('audit').then { [it.harness, it.session_id] })
  end

  def test_join_refuses_an_address_a_live_session_holds_unless_forced
    join_claude('rev-1', 111)
    alive << 222
    refused = keryx('join', 'rev-1', env: claude(222))

    assert_equal 1, refused.status
    assert_match(/rev-1@athena is held by another live claude session \(pid 111\); pass --force/, refused.err)
    assert_equal 0, keryx('join', 'rev-1', '--force', env: claude(222)).status
    assert_equal 222, store.occupant('rev-1').pid
  end

  def test_join_takes_an_address_whose_session_is_gone
    join_claude('rev-1', 111)
    alive.delete(111)
    alive << 222

    assert_equal 0, keryx('join', 'rev-1', env: claude(222)).status
  end

  def test_joining_another_address_releases_the_first
    env = join_claude('rev-1', 111)
    keryx('join', 'rev-2', env:)

    assert_nil store.occupant('rev-1')
    assert_equal 111, store.occupant('rev-2').pid
  end

  def test_join_reports_mail_waiting_for_the_address
    keryx('join', 'rev-1', env: claude(111).tap { alive << 111 })
    keryx('leave', env: claude(111))
    keryx('send', 'rev-1', 'are you there?')
    alive << 222

    assert_match(/1 unread message\(s\) waiting/, keryx('join', 'rev-1', env: claude(222)).out)
  end

  def test_leave_releases_and_keeps_the_mailbox
    env = join_claude('rev-1', 111)
    result = keryx('leave', env:)

    assert_equal "Left rev-1@athena. Its mailbox keeps receiving.\n", result.out
    assert_nil store.occupant('rev-1')
    assert store.address?('rev-1')
    assert_equal 1, keryx('leave', env:).status
  end

  def test_leave_as_releases_an_address_whose_session_ended_and_keeps_its_mail
    join_claude('rev-1', 111)
    keryx('send', 'rev-1', 'are you there?')
    alive.delete(111)
    result = keryx('leave', '--as', 'rev-1')

    assert_equal 0, result.status, result.err
    assert_equal 'Released rev-1@athena from its claude session (pid 111), which keryx does not see running. Its ' \
                 "mailbox keeps receiving.\n", result.out
    assert_nil store.occupant('rev-1')
    assert_equal ['are you there?'], store.unread('rev-1').map(&:body)
  end

  def test_leave_as_releases_a_codex_thread_closed_in_its_pane_or_without_one
    keryx('join', 'impl', env: { 'CODEX_THREAD_ID' => 'thread-1', 'HERDR_SOCKET_PATH' => '/h.sock',
                                 'HERDR_PANE_ID' => 'w1:p3' })
    keryx('join', 'docs', env: { 'CODEX_THREAD_ID' => 'thread-2' })

    assert_equal [0, 0], [keryx('leave', '--as', 'impl').status, keryx('leave', env: { 'KERYX_AS' => 'docs' }).status]
    assert_nil store.occupant('impl')
    assert_nil store.occupant('docs')
  end

  def test_leave_as_refuses_an_address_a_live_session_holds
    join_claude('rev-1', 111)
    result = keryx('leave', '--as', 'rev-1')

    assert_equal 1, result.status
    assert_equal 'error: rev-1@athena is held by another live claude session (pid 111); only that session can ' \
                 "release it, with 'keryx leave'\n", result.err
    assert_equal 111, store.occupant('rev-1').pid
  end

  def test_leave_as_needs_an_address_that_a_session_holds
    env = join_claude('rev-1', 111)
    keryx('leave', env:)

    assert_equal "error: no session holds rev-1@athena\n", keryx('leave', '--as', 'rev-1').err
    assert_match(/no address ghost/, keryx('leave', '--as', 'ghost').err)
  end

  def test_leave_as_the_address_this_session_holds_is_a_plain_leave
    env = join_claude('rev-1', 111)
    result = keryx('leave', '--as', 'rev-1', env:)

    assert_equal "Left rev-1@athena. Its mailbox keeps receiving.\n", result.out
    assert_nil store.occupant('rev-1')
  end

  def test_whoami_for_an_agent_and_for_a_person
    env = join_claude('rev-1', 111, role: 'reviewer')

    assert_match(/\Arev-1@athena\nrole +reviewer\nunread +0\nharness +claude\nsession +pid 111\njoined +0s ago\n\z/,
                 keryx('whoami', env:).out)
    assert_equal 'person@athena', JSON.parse(keryx('whoami', '-o', 'json').out)['address']
  end

  def test_an_agent_that_did_not_join_cannot_act
    alive << 111
    result = keryx('inbox', env: claude(111))

    assert_equal 1, result.status
    assert_match(/this claude session holds no address; run 'keryx join NAME'/, result.err)
  end

  def test_who_lists_addresses_with_their_sessions
    join_claude('orq', 111, role: 'orchestrator')
    join_claude('rev-1', 222)
    alive.delete(222)
    keryx('send', 'rev-1', 'hello')
    lines = keryx('who').out.lines.map(&:split)

    assert_equal [%w[ADDRESS ROLE HARNESS SESSION UNREAD], %w[orq@athena orchestrator claude live 0],
                  %w[person@athena human - none 0], %w[rev-1@athena - claude gone 1]], lines
  end

  def test_who_shows_herdr_state_for_panes
    @herdr = FakeHerdr.new({ ['/h.sock', 'w1:p2'] => Keryx::Herdr::Agent.new('w1:p2', 'codex', 'working') })
    keryx('join', 'impl', env: { 'HERDR_SOCKET_PATH' => '/h.sock', 'HERDR_PANE_ID' => 'w1:p2' })

    assert_equal 'working', JSON.parse(keryx('who', '-o', 'json').out).first['session']
  end

  def test_who_with_no_addresses
    assert_match(/No addresses yet/, keryx('who').out)
  end

  def test_a_session_restarted_in_its_pane_keeps_the_address_and_updates_it
    pane = { 'HERDR_SOCKET_PATH' => '/h.sock', 'HERDR_PANE_ID' => 'w1:p1' }
    join_claude('rev-1', 111).merge(pane).then { keryx('join', 'rev-1', env: it) }
    alive << 222
    keryx('inbox', env: claude(222).merge(pane))

    assert_equal([222, '/tmp/cc-222.sock'], store.occupant('rev-1').then { [it.pid, it.claude_socket] })
  end
end
