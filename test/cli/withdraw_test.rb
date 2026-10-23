# frozen_string_literal: true

require 'test_helper'

class WithdrawTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  OLD_NAME = { 'KERYX_HOST' => 'lap-0042' }.freeze

  def setup
    super
    @orq = join_claude('orq.dev', 111)
    @impl = join_claude('impl.dev', 222)
  end

  def open_ids(env = {}) = JSON.parse(keryx('status', '-o', 'json', env:).out)['open_requests'].map { it['id'] }

  def stop(env)
    keryx('hook', 'stop', env:, input: JSON.generate('session_id' => env['CLAUDE_CODE_SESSION_ID'])).out
  end

  def withdrawals(name) = store.mailbox(name).map(&:message).select(&:withdrawal?)

  def asked(recipient, env: @orq)
    keryx('ask', recipient, 'Fix retry.py', '--within', '1m', env:).out[/\AAsked \S+ \((\w{26})\)/, 1]
  end

  def inbox(env) = JSON.parse(keryx('inbox', '--all', '-o', 'json', env:).out)

  def due_column(env) = keryx('inbox', '--all', env:).out.lines.drop(1).to_h { it.split(/ {3,}/).values_at(0, 4) }

  def join_port
    alive << 333
    machine('zeus').merge(claude(333)).tap { keryx('join', 'port.dev', env: it) }
  end

  def zeus_withdrawal = Keryx::Store.new(tmp('zeus')).mailbox('port.dev').map(&:message).find(&:withdrawal?)

  # What NAME, which has not opened WITHDRAWAL yet, sees of the request ID it withdraws.
  def assert_withdrawn(name, env, id, withdrawal, reason: nil)
    time = withdrawal.created_at.utc.strftime('%Y-%m-%d %H:%M:%S UTC')
    note = "\n\nIts sender withdrew this request, so it needs no reply.\n#{"Reason: #{reason}\n" if reason}"

    assert_equal "keryx: #{name} has 1 unread message (#{withdrawal.id}). Open each with 'keryx read ID' before " \
                 'ending the turn.', JSON.parse(stop(env))['reason']
    read = keryx('read', id, env:).out

    assert_match(/^withdrawn +#{withdrawal.id} at #{time} \(\w+ ago\)\n\n/, read)
    assert_equal note, read[-note.size..]
    refute_includes read, 'Answer with'
    assert_equal 'withdrawn', due_column(env)[id]
    records = [JSON.parse(keryx('read', id, '-o', 'json', env:).out), inbox(env).find { it['id'] == id }]

    assert_equal([withdrawal.id] * 2, records.map { it['withdrawn_by'] })
  end

  def test_the_sender_withdraws_a_request_sent_before_the_machine_was_renamed
    id = asked('impl.dev', env: @orq.merge(OLD_NAME))
    keryx('read', id, env: @impl)

    assert_equal [id], open_ids
    withdrawn = keryx('withdraw', id[0, 8].downcase, env: @orq)
    withdrawal = withdrawals('impl.dev').first

    assert_match(/\AWithdrew #{id}, sent to impl.dev@lap-0042 \(#{withdrawal.id}\)\. The bell rang through claude\./,
                 withdrawn.out)
    fields = withdrawal.to_h.values_at(:from, :to, :thread, :in_reply_to)

    assert_equal ['orq.dev@lap-0042', 'impl.dev@lap-0042', id, id], fields
    refute_path_exists tmp('state', 'outbox', 'lap-0042')
    assert_empty open_ids
  end

  def test_the_recipients_hook_stops_reminding_of_a_withdrawn_request
    id = asked('impl.dev', env: @orq.merge(OLD_NAME))
    keryx('read', id, env: @impl)
    keryx('withdraw', id, env: @orq)
    reminder = JSON.parse(stop(@impl))['reason']

    assert_match(/has 1 unread message \(#{withdrawals('impl.dev').first.id}\)\./, reminder)
    refute_includes reminder, 'not answered'
    keryx('read', env: @impl)

    assert_empty stop(@impl)
  end

  def test_only_the_address_that_sent_a_request_from_this_machine_withdraws_it
    id = asked('impl.dev', env: @orq.merge(OLD_NAME))
    inbound = build_message(to: 'impl.dev@athena', from: 'orq.dev@zeus', kind: 'request')
    store.deliver('impl.dev', inbound)
    rev = join_claude('rev-1.dev', 333)
    refusals = [keryx('withdraw', id, env: rev), keryx('withdraw', inbound.id, env: @orq)]

    assert_equal [1, 1], refusals.map(&:status)
    assert_equal ["error: no request #{id} sent by rev-1.dev@athena\n",
                  "error: no request #{inbound.id} sent by orq.dev@athena\n"], refusals.map(&:err)
    assert_empty withdrawals('impl.dev')
  end

  def test_a_request_answered_or_withdrawn_already_is_refused
    id = asked('impl.dev')
    keryx('withdraw', id, env: @orq)
    again = keryx('withdraw', id, env: @orq)
    answered = asked('impl.dev')
    keryx('reply', answered, 'Done', env: @impl)
    late = keryx('withdraw', answered, env: @orq)

    assert_equal "error: #{id} was withdrawn already (#{withdrawals('impl.dev').first.id})\n", again.err
    assert_match(/\Aerror: #{answered} is answered already \(\w{26}\); there is nothing to withdraw\n\z/, late.err)
  end

  def test_a_request_to_another_machine_closes_on_each_once_it_holds_the_withdrawal
    port = machine('zeus').merge(claude(333))
    alive << 333
    keryx('join', 'port.dev', env: port)
    keryx('ask', 'port.dev@zeus', 'Port it', env: @orq.merge(OLD_NAME))
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
    id = asked('impl.dev')
    keryx('withdraw', id, 'The tests already cover it', env: @orq)
    waited = keryx('wait', id, env: @orq)

    assert_equal 0, waited.status
    assert_match(/\Aid +\w{26}\nkind +withdrawal\n.*\nwithdraws +#{id}\n.*\n\nThe tests already cover it\n\z/m,
                 waited.out)
    assert_match(/\AReplied to orq.dev@athena/, keryx('reply', id, 'Done anyway', env: @impl).out)
    reply = last_id(@orq)

    assert_match(/\n\nDone anyway\n/, keryx('read', reply, env: @orq).out)
    assert_equal 'reply', JSON.parse(keryx('wait', id, '-o', 'json', env: @orq).out)['kind']
  end

  def test_a_request_withdrawn_before_it_was_read_is_not_reminded_and_reads_as_withdrawn
    id = asked('impl.dev')
    clock.advance(60)
    keryx('withdraw', id, 'Fixed upstream', env: @orq)

    assert_withdrawn('impl.dev', @impl, id, withdrawals('impl.dev').first, reason: 'Fixed upstream')
  end

  def test_a_withdrawal_that_gives_no_reason_adds_none_to_the_request
    id = asked('impl.dev')
    keryx('withdraw', id, env: @orq)

    assert_withdrawn('impl.dev', @impl, id, withdrawals('impl.dev').first)
  end

  def test_a_request_left_unread_once_its_withdrawal_is_read_is_listed_as_withdrawn_and_not_reminded
    id = asked('impl.dev')
    keryx('withdraw', id, env: @orq)
    keryx('read', withdrawals('impl.dev').first.id, env: @impl)
    unread = keryx('inbox', env: @impl).out.lines.drop(1).map { it.split(/ {3,}/).values_at(0, 4) }

    assert_equal [[id, 'withdrawn']], unread
    assert_empty stop(@impl)
  end

  def test_a_request_and_its_withdrawal_that_arrive_from_another_machine_read_as_withdrawn
    port = join_port
    keryx('ask', 'port.dev@zeus', 'Port it', env: @orq)
    id = last_id(port)
    keryx('withdraw', id, 'Not needed after all', env: @orq)
    withdrawal = zeus_withdrawal

    assert_equal [['zeus', [id]], ['zeus', [withdrawal.id]]], remote.sent
    assert_withdrawn('port.dev', port, id, withdrawal, reason: 'Not needed after all')
  end

  def test_a_withdrawal_from_anyone_but_the_sender_leaves_the_request_to_answer
    request = build_message(to: 'impl.dev@athena', from: 'orq.dev@zeus', kind: 'request', id: Keryx::Ulid.generate(NOW))
    forged = build_message(to: 'impl.dev@athena', from: 'eve.dev@zeus', kind: 'withdrawal', id: Keryx::Ulid.generate(NOW + 1),
                           in_reply_to: request.id, thread: request.id)
    keryx('__receive', input: [request, forged].map { "#{it.to_json}\n" }.join)

    assert_match(/has 2 unread messages \(#{request.id}, #{forged.id}\)\. .* answer every request with/,
                 JSON.parse(stop(@impl))['reason'])
    assert_match(/\n\nAnswer with: keryx reply #{request.id} TEXT\n\z/, keryx('read', request.id, env: @impl).out)
    assert_equal({ request.id => '-', forged.id => '-' }, due_column(@impl))
    assert_equal([[request.id, nil], [forged.id, false]],
                 inbox(@impl).map { [it['id'], it.fetch('withdrawn_by', false)] })
  end

  def test_a_reply_to_a_request_withdrawn_before_it_was_read_is_delivered_and_the_request_stays_withdrawn
    id = asked('impl.dev')
    keryx('withdraw', id, env: @orq)
    keryx('reply', id, 'Done anyway', env: @impl)

    assert_equal([['reply', 'Done anyway']], inbox(@orq).map { it.values_at('kind', 'body') })
    assert_withdrawn('impl.dev', @impl, id, withdrawals('impl.dev').first)
  end

  def test_a_reply_from_another_machine_to_a_request_withdrawn_there_is_delivered_and_it_stays_withdrawn
    port = join_port
    keryx('ask', 'port.dev@zeus', 'Port it', env: @orq)
    id = last_id(port)
    keryx('withdraw', id, env: @orq)
    replied = keryx('reply', id, 'Ported anyway', env: port)

    assert_match(/\AReplied to orq.dev@athena \(\w{26}\)\. It reached athena\./, replied.out)
    assert_equal([['reply', 'Ported anyway']], inbox(@orq).map { it.values_at('kind', 'body') })
    assert_withdrawn('port.dev', port, id, zeus_withdrawal)
  end

  def test_a_withdrawal_rings_the_recipient_and_ends_the_deadline_notices
    id = asked('impl.dev')
    keryx('withdraw', id, env: @orq)
    clock.advance(120)

    assert_match(/\[keryx\] New withdrawal for impl.dev@athena from orq.dev@athena/, sockets.posts.last.last)
    refute_match(/past its deadline/, keryx('courier', '--once').out)
    assert_equal "Request #{id} is withdrawn and needs no reply.", withdrawals('impl.dev').first.body
  end
end
