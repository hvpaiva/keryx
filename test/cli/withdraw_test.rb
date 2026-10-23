# frozen_string_literal: true

require 'test_helper'

class WithdrawTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  OLD_NAME = { 'KERYX_HOST' => 'lap-0042' }.freeze

  def setup
    super
    @orq = join_claude('orq', 111)
    @impl = join_claude('impl', 222)
  end

  def open_ids(env = {}) = JSON.parse(keryx('status', '-o', 'json', env:).out)['open_requests'].map { it['id'] }

  def stop(env)
    keryx('hook', 'stop', env:, input: JSON.generate('session_id' => env['CLAUDE_CODE_SESSION_ID'])).out
  end

  def withdrawals(name) = store.mailbox(name).map(&:message).select(&:withdrawal?)

  def asked(recipient, env: @orq)
    keryx('ask', recipient, 'Fix retry.py', '--within', '1m', env:).out[/\AAsked \S+ \((\w{26})\)/, 1]
  end

  def test_the_sender_withdraws_a_request_sent_before_the_machine_was_renamed
    id = asked('impl', env: @orq.merge(OLD_NAME))
    keryx('read', id, env: @impl)

    assert_equal [id], open_ids
    withdrawn = keryx('withdraw', id[0, 8].downcase, env: @orq)
    withdrawal = withdrawals('impl').first

    assert_match(/\AWithdrew #{id}, sent to impl@lap-0042 \(#{withdrawal.id}\)\. The bell rang through claude\./,
                 withdrawn.out)
    fields = withdrawal.to_h.values_at(:from, :to, :thread, :in_reply_to)

    assert_equal ['orq@lap-0042', 'impl@lap-0042', id, id], fields
    refute_path_exists tmp('state', 'outbox', 'lap-0042')
    assert_empty open_ids
  end

  def test_the_recipients_hook_stops_reminding_of_a_withdrawn_request
    id = asked('impl', env: @orq.merge(OLD_NAME))
    keryx('read', id, env: @impl)
    keryx('withdraw', id, env: @orq)
    reminder = JSON.parse(stop(@impl))['reason']

    assert_match(/has 1 unread message \(#{withdrawals('impl').first.id}\)\./, reminder)
    refute_includes reminder, 'not answered'
    keryx('read', env: @impl)

    assert_empty stop(@impl)
  end

  def test_only_the_address_that_sent_a_request_from_this_machine_withdraws_it
    id = asked('impl', env: @orq.merge(OLD_NAME))
    inbound = build_message(to: 'impl@athena', from: 'orq@zeus', kind: 'request').tap { store.deliver('impl', it) }
    rev = join_claude('rev-1', 333)
    refusals = [keryx('withdraw', id, env: rev), keryx('withdraw', inbound.id, env: @orq)]

    assert_equal [1, 1], refusals.map(&:status)
    assert_equal ["error: no request #{id} sent by rev-1@athena\n",
                  "error: no request #{inbound.id} sent by orq@athena\n"], refusals.map(&:err)
    assert_empty withdrawals('impl')
  end

  def test_a_request_answered_or_withdrawn_already_is_refused
    id = asked('impl')
    keryx('withdraw', id, env: @orq)
    again = keryx('withdraw', id, env: @orq)
    answered = asked('impl')
    keryx('reply', answered, 'Done', env: @impl)
    late = keryx('withdraw', answered, env: @orq)

    assert_equal "error: #{id} was withdrawn already (#{withdrawals('impl').first.id})\n", again.err
    assert_match(/\Aerror: #{answered} is answered already \(\w{26}\); there is nothing to withdraw\n\z/, late.err)
  end

  def test_a_request_to_another_machine_closes_on_each_once_it_holds_the_withdrawal
    port = machine('zeus').merge(claude(333))
    alive << 333
    keryx('join', 'port', env: port)
    keryx('ask', 'port@zeus', 'Port it', env: @orq.merge(OLD_NAME))
    id = last_id(port)
    clock.advance(1)
    remote.down << 'zeus'
    queued = keryx('withdraw', id, env: @orq)

    assert_match(/zeus did not answer .*; the message waits in the outbox/, queued.out)
    assert_equal [[], [id]], [open_ids, open_ids(port)]
    remote.down.clear
    keryx('courier', '--once')

    assert_equal [[], []], [open_ids, open_ids(port)]
    assert_equal(%w[request withdrawal], JSON.parse(keryx('inbox', '-o', 'json', env: port).out).map { it['kind'] })
  end

  def test_a_reply_after_the_withdrawal_is_delivered_and_wait_shows_what_settled_the_request
    id = asked('impl')
    keryx('withdraw', id, 'The tests already cover it', env: @orq)
    waited = keryx('wait', id, env: @orq)

    assert_equal 0, waited.status
    assert_match(/\Aid +\w{26}\nkind +withdrawal\n.*\nwithdraws +#{id}\n.*\n\nThe tests already cover it\n\z/m,
                 waited.out)
    assert_match(/\AReplied to orq@athena/, keryx('reply', id, 'Done anyway', env: @impl).out)
    reply = last_id(@orq)

    assert_match(/\n\nDone anyway\n/, keryx('read', reply, env: @orq).out)
    assert_equal 'reply', JSON.parse(keryx('wait', id, '-o', 'json', env: @orq).out)['kind']
  end

  def test_a_withdrawal_rings_the_recipient_and_ends_the_deadline_notices
    id = asked('impl')
    keryx('withdraw', id, env: @orq)
    clock.advance(120)

    assert_match(/\[keryx\] New withdrawal for impl@athena from orq@athena/, sockets.posts.last.last)
    refute_match(/past its deadline/, keryx('courier', '--once').out)
    assert_equal "Request #{id} is withdrawn and needs no reply.", withdrawals('impl').first.body
  end
end
