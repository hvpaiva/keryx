# frozen_string_literal: true

require 'test_helper'

class HandoverTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def setup
    super
    @orq = join_claude('orq.dev', 111)
    @old = join_claude('rev-1.dev', 222)
    @session = store.occupant('rev-1.dev').session
    @new = claude(333)
  end

  def take_over
    alive << 333
    result = keryx('join', 'rev-1.dev', '--force', env: @new)
    raise "join failed: #{result.err}" unless result.status.zero?

    result
  end

  def old_address = "rev-1.dev@athena/#{@session}"

  def unread(env) = JSON.parse(keryx('inbox', '-o', 'json', env:).out)

  def bodies(env) = unread(env).map { it['body'] }

  def addresses(output) = output.lines.drop(1).map { it.split.first }

  def stop(env)
    input = JSON.generate('session_id' => env['CLAUDE_CODE_SESSION_ID'], 'hook_event_name' => 'Stop')
    out = keryx('hook', 'stop', env:, input:).out
    JSON.parse(out)['reason'] unless out.empty?
  end

  def test_join_force_leaves_the_running_session_bound_at_its_session_address
    joined = take_over
    holder = store.occupant('rev-1.dev').session
    whoami = [@old, @new].map { JSON.parse(keryx('whoami', '-o', 'json', env: it).out) }

    assert_match(/\A[0-9a-hjkmnp-tv-z]{6}\z/, @session)
    refute_equal @session, holder
    assert_equal([[old_address, old_address], ['rev-1.dev@athena', "rev-1.dev@athena/#{holder}"]],
                 whoami.map { it.values_at('address', 'session_address') })
    assert_match "The session that held it stays reachable at #{old_address} until it leaves.", joined.out
  end

  def test_mail_to_the_stable_address_rings_the_holder_and_mail_to_the_old_session_only_that_session
    take_over
    keryx('send', 'rev-1.dev', 'For the holder', env: @orq)
    keryx('send', "rev-1.dev/#{@session}", 'For the old session', env: @orq)

    assert_equal %w[/tmp/cc-333.sock /tmp/cc-222.sock], sockets.posts.last(2).map(&:first)
    assert_equal([['For the holder'], ['For the old session']], [@new, @old].map { bodies(it) })
    assert_equal old_address, unread(@old).first['to']
  end

  def test_the_old_sessions_own_mail_carries_its_session_address_so_the_reply_comes_back_to_it
    take_over
    keryx('ask', 'orq', 'Is the old work still wanted?', env: @old)
    request = unread(@orq).last
    keryx('reply', request['id'], 'Yes', env: @orq)

    assert_equal old_address, request['from']
    assert_equal([['Yes'], []], [@old, @new].map { bodies(it) })
    assert_equal '/tmp/cc-222.sock', sockets.posts.last.first
  end

  def test_a_displaced_session_answers_by_id_the_request_it_took_before_the_handover
    keryx('ask', 'rev-1.dev', 'Review PR #448', '--within', '30m', env: @orq)
    id = last_id(@old)
    keryx('send', '--re', id, 'On it', env: @old)
    take_over
    clock.advance(1)
    replied = keryx('reply', id, 'Done', env: @old)

    assert_equal [0, ''], [replied.status, replied.err]
    assert_empty JSON.parse(keryx('status', '-o', 'json').out)['open_requests']
    assert_equal([['On it', 'rev-1.dev@athena'], ['Done', 'rev-1.dev@athena']],
                 unread(@orq).map { it.values_at('body', 'from') })
  end

  def test_a_displaced_session_lists_only_its_own_mail_and_opens_no_other_sessions_mail_by_id
    take_over
    keryx('send', 'rev-1.dev', 'Stable', env: @orq)
    clock.advance(1)
    keryx('send', "rev-1.dev/#{store.occupant('rev-1.dev').session}", 'For the holder', env: @orq)
    stable, holders = unread(@new).map { it['id'] }

    assert_empty bodies(@old)
    assert_equal 0, keryx('read', stable, env: @old).status
    assert_match(/no message #{holders}/, keryx('read', holders, env: @old).err)
  end

  def test_mail_to_a_session_that_ended_or_left_is_refused_here_and_from_another_machine
    take_over
    alive.delete(222)
    ended = keryx('send', old_address, 'Still there?', env: @orq)
    released = keryx('leave', '--as', "rev-1.dev/#{@session}")
    alive << 444
    keryx('join', 'port.dev', env: machine('zeus').merge(claude(444)))
    remote_send = keryx('send', old_address, 'Still there?', env: machine('zeus').merge(claude(444)))
    refusal = "mail to #{old_address} is refused: its session left; write to rev-1.dev@athena"

    assert_equal "error: #{refusal}\n", ended.err
    assert_match(/\AReleased #{old_address} from its claude session \(pid 222\)/, released.out)
    assert_equal "error: athena refused the message; #{refusal}\n", remote_send.err
    assert_equal %w[orq.dev@athena rev-1.dev@athena], addresses(keryx('who').out)
  end

  def test_ring_refuses_the_session_address_of_a_session_that_left
    take_over
    keryx('send', old_address, 'For the old session', env: @orq)
    rung = keryx('ring', old_address)
    keryx('leave', env: @old)
    refused = keryx('ring', "rev-1.dev/#{@session}")

    assert_equal "#{old_address}   1 unread   rung via claude\n", rung.out
    assert_equal [1, "error: mail to #{old_address} is refused: its session left; write to rev-1.dev@athena\n"],
                 [refused.status, refused.err]
  end

  def test_leave_releases_the_displaced_session_and_leave_as_waits_until_it_ended
    take_over
    refused = keryx('leave', '--as', "rev-1.dev/#{@session}")
    left = keryx('leave', env: @old)

    assert_match(/\Aerror: #{old_address} is held by another live claude session \(pid 222\)/, refused.err)
    assert_equal "Left #{old_address}. Mail to it is refused from now on; a withdrawal written here still " \
                 "reaches it.\n", left.out
    assert_equal 'rev-1.dev@athena', JSON.parse(keryx('whoami', '-o', 'json', env: @new).out)['address']
  end

  def test_who_and_status_show_the_displaced_session_below_its_address
    take_over
    status = keryx('status').out.split("\n\n").find { it.start_with?('ADDRESSES') }.lines.drop(1).join

    assert_equal ['orq.dev@athena', 'rev-1.dev@athena', old_address], addresses(keryx('who').out)
    assert_equal ['orq.dev@athena', 'rev-1.dev@athena', old_address], addresses(status)
  end

  def test_who_status_and_whoami_spell_out_member_team_host_and_session_address_in_json
    take_over
    fields = %w[address member team host session_address]
    rows = %w[who status].map { |command| JSON.parse(keryx(command, '-o', 'json').out)['addresses'] }
    sessions = %w[orq.dev rev-1.dev].map { store.occupant(it).session }
    expected = [['orq.dev@athena', 'orq', 'dev', 'athena', "orq.dev@athena/#{sessions.first}"],
                ['rev-1.dev@athena', 'rev-1', 'dev', 'athena', "rev-1.dev@athena/#{sessions.last}"],
                [old_address, 'rev-1', 'dev', 'athena', old_address]]

    assert_equal([expected] * 2, rows.map { |records| records.map { it.values_at(*fields) } })
    assert_equal expected.last, JSON.parse(keryx('whoami', '-o', 'json', env: @old).out).values_at(*fields)
    assert_equal 'live', rows.first.last['session']
  end

  def test_a_refresh_keeps_the_session_and_each_join_draws_a_new_one
    keryx('whoami', env: @old.merge('CLAUDE_CODE_MESSAGING_SOCKET' => '/tmp/cc-222-new.sock'))
    refreshed = store.occupant('rev-1.dev')
    keryx('join', 'rev-1.dev', env: @old)

    assert_equal ['/tmp/cc-222-new.sock', @session], refreshed.to_h.values_at(:claude_socket, :session)
    refute_equal @session, store.occupant('rev-1.dev').session
  end

  def test_a_join_over_a_session_that_ended_keeps_no_session_address_for_it
    alive.delete(222)
    joined = take_over

    refute_match(/stays reachable/, joined.out)
    assert_equal %w[orq.dev@athena rev-1.dev@athena], addresses(keryx('who').out)
    assert_match(/its session left/, keryx('send', old_address, 'Still there?', env: @orq).err)
  end

  def test_the_stop_hook_of_a_displaced_session_names_only_its_session_mail
    take_over
    keryx('send', 'rev-1.dev', 'Stable', env: @orq)
    quiet = stop(@old)
    keryx('send', old_address, 'For the old session', env: @orq)

    assert_nil quiet
    assert_match(/has 1 unread message \(#{unread(@old).first['id']}\)/, stop(@old))
  end

  def test_a_displaced_session_withdraws_only_the_requests_it_sent
    take_over
    keryx('ask', 'orq.dev', 'Still wanted?', env: @old)
    id = unread(@orq).last['id']
    by_holder = keryx('withdraw', id, env: @new)
    withdrawn = keryx('withdraw', id, env: @old)

    assert_match(/no request #{id} sent by rev-1.dev@athena/, by_holder.err)
    assert_equal [0, ''], [withdrawn.status, withdrawn.err]
  end

  def test_a_withdrawal_written_here_still_reaches_a_session_address_once_its_session_left
    take_over
    keryx('ask', "rev-1.dev/#{@session}", 'Still wanted?', env: @orq)
    id = unread(@old).last['id']
    keryx('leave', env: @old)
    withdrawn = keryx('withdraw', id, env: @orq)

    assert_equal [0, ''], [withdrawn.status, withdrawn.err]
    assert_equal [id], store.mailbox('rev-1.dev').map(&:message).select(&:withdrawal?).map(&:in_reply_to)
  end

  def test_retire_waits_for_the_displaced_session_to_end
    take_over
    keryx('leave', env: @new)
    refused = keryx('retire', 'rev-1.dev')
    keryx('leave', env: @old)

    assert_match(/\Aerror: #{old_address} is held by another live claude session/, refused.err)
    assert_equal 0, keryx('retire', 'rev-1.dev').status
  end
end
