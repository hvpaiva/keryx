# frozen_string_literal: true

require 'test_helper'

# Between machines each one runs its own checker: the sender's on send, the receiver's on receive, with no command.
class MessageCheckRemoteTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include MessageCheckHelpers

  ZEUS_REASON = "no ticket named\nin the first line"
  RECEIVED = 'the check on zeus refused the message: no ticket named in the first line'
  OUT_OF_TIME = 'zeus could not store it; the check on zeus ran out of time in this batch'

  # A checker on zeus that accepts each message after 35 s of the helper's monotonic clock, against a timeout of 5 s
  # and Receiver's budget of 40 s, so a batch checks one message.
  class SlowChecker
    attr_reader :ids

    def initialize(monotonic)
      @monotonic = monotonic
      @ids = []
    end

    def call(_setup, envelope)
      @ids << JSON.parse(envelope).dig('message', 'id')
      @monotonic.advance(35)
      Keryx::Checker::Outcome.new(status: 0)
    end
  end

  def setup
    super
    @orq = join_claude('orq.dev', 111)
    alive << 333
    @port = machine('zeus').merge(claude(333))
    must(keryx('join', 'port.dev', env: @port))
  end

  def test_athena_accepts_and_zeus_refuses_a_send_between_machines
    accepting
    refusing('zeus', reason: ZEUS_REASON)
    sent = keryx('send', 'port.dev@zeus', 'Port retry.py', env: @orq)

    assert_equal [1, '', "error: zeus refused the message; #{RECEIVED}\n"], [sent.status, sent.out, sent.err]
    assert_empty zeus.stored('port.dev')
    assert_empty store.outbox.outgoing
    assert_equal([%w[send send athena]], envelopes.map { it.values_at('event', 'command', 'host') })
    assert_equal([['receive', nil, 'zeus']], envelopes('zeus').map { it.values_at('event', 'command', 'host') })
    assert_equal envelopes.first['message'], envelopes('zeus').first['message']
  end

  def test_a_refusal_when_the_courier_forwards_shows_under_not_forwarded
    refusing('zeus', reason: ZEUS_REASON)
    remote.down << 'zeus'
    must(keryx('send', 'port.dev@zeus', 'Port retry.py', env: @orq))
    id = store.outbox.queued('zeus').first.id
    remote.down.clear
    courier = keryx('courier', '--once')

    assert_equal [0, "zeus refused #{id}: #{RECEIVED}\n"], [courier.status, courier.out]
    assert_equal([[id, 'port.dev@zeus', 'refused', RECEIVED]],
                 not_forwarded.map { it.values_at('id', 'to', 'state', 'detail') })
    row = /^#{id}\s+port\.dev@zeus\s+orq\.dev@athena\s+refused\s+\d+\s+#{Regexp.escape(RECEIVED)}$/

    assert_match(/^NOT FORWARDED\n.*\n#{row}/, keryx('status').out)
    assert_empty zeus.stored('port.dev')
  end

  def test_a_reply_refused_by_athenas_check_leaves_the_request_open_on_athena
    must(keryx('ask', 'port.dev@zeus', 'Port retry.py', env: @orq))
    id = last_id(@port)
    refusing
    replied = keryx('reply', id, 'Done in retry.go', env: @port)

    assert_equal [1, "error: athena refused the message; the check on athena refused the message: #{REASON}\n"],
                 [replied.status, replied.err]
    assert_empty store.stored('orq.dev')
    assert_equal [id], open_requests
    assert_equal([['receive', nil, 'athena']], envelopes.map { it.values_at('event', 'command', 'host') })
  end

  def test_a_person_on_zeus_reaches_athena_past_its_refusing_check
    refusing
    sent = keryx('send', 'orq.dev@athena', 'From the desk', env: machine('zeus'))

    assert_equal [0, ''], [sent.status, sent.err]
    assert_match(/\ASent \w{26} to orq.dev@athena\. It reached athena\./, sent.out)
    assert_equal([['person.local@zeus', 'From the desk']],
                 store.stored('orq.dev').map { it.message.then { |m| [m.from, m.body] } })
    refute_path_exists record
  end

  def test_a_notice_from_keryx_on_zeus_is_received_past_athenas_refusing_check
    refusing
    notice = build_message(from: 'keryx.system@zeus', to: 'orq.dev@athena', body: 'port.dev@zeus is near its ceiling')
    received = keryx('__receive', input: "#{notice.to_json}\n")

    assert_equal [0, 'delivered'], [received.status, JSON.parse(received.out)['status']]
    assert_equal([JSON.parse(notice.to_json)], store.stored('orq.dev').map { JSON.parse(it.message.to_json) })
    refute_path_exists record
  end

  # Only keryx.system is keryx's own; another member of the system team is checked as any agent is.
  def test_a_message_from_another_member_of_the_system_team_is_checked_on_receive
    refusing
    message = build_message(from: 'other.system@zeus', to: 'orq.dev@athena', body: 'Not a notice')
    received = keryx('__receive', input: "#{message.to_json}\n")

    assert_equal [0, 'refused', "the check on athena refused the message: #{REASON}"],
                 [received.status, *JSON.parse(received.out).values_at('status', 'detail')]
    assert_empty store.stored('orq.dev')
    assert_equal([message.id], envelopes.map { it.dig('message', 'id') })
  end

  # A failed receipt would have the sender send it again on every pass, so a check that fails refuses.
  def test_a_checker_on_zeus_that_exits_2_refuses_the_message_rather_than_failing_it
    check_with(path = checker('zeus', status: 2, reason: "policy down\nsince noon"), host: 'zeus')
    sent = keryx('send', 'port.dev@zeus', 'Port retry.py', env: @orq)

    assert_equal [1, '', "error: zeus refused the message; the check on zeus failed: #{path} exited with status 2: " \
                         "policy down since noon\n"], [sent.status, sent.out, sent.err]
    assert_empty zeus.stored('port.dev')
    assert_empty store.outbox.outgoing
    assert_equal 1, envelopes('zeus').size
  end

  def test_a_nul_byte_in_the_receiving_machines_check_file_refuses_the_message
    check_with("#{checker('athena')}\0x")
    message = build_message(from: 'port.dev@zeus', to: 'orq.dev@athena', body: 'Done in retry.go')
    received = keryx('__receive', input: "#{message.to_json}\n")

    assert_equal [0, 'refused', "the check on athena failed: #{check_path}:1: holds a NUL byte"],
                 [received.status, *JSON.parse(received.out).values_at('status', 'detail')]
    assert_empty store.stored('orq.dev')
    refute_path_exists record
  end

  def slow = @slow ||= SlowChecker.new(monotonic)

  # zeus's check reads a real file naming a valid checker, which the slow one stands in for.
  def slow_on_zeus
    check_with(checker('zeus'), host: 'zeus')
    checks['zeus'] = Keryx::Check.new(host: 'zeus', checker: slow,
                                      config: Keryx::CheckConfig.new(path: check_path('zeus'), trusted: TRUSTED))
  end

  # While zeus is down, orq asks port.dev@zeus and adds to the request twice, three messages of one thread queued in
  # the order written.
  def three_in_one_thread
    remote.down << 'zeus'
    must(keryx('ask', 'port.dev@zeus', 'Port retry.py', env: @orq))
    request = store.outbox.queued('zeus').first.id
    %w[tests docs].each do |part|
      clock.advance(1)
      must(keryx('send', '--on', request, "Port the #{part} too", env: @orq))
    end
    remote.down.clear
    store.outbox.queued('zeus').map(&:id)
  end

  # One courier round, which forwards FORWARDED and leaves WAITING queued on athena, by id with its detail.
  def assert_round(forwarded, waiting)
    round = keryx('courier', '--once')

    assert_equal [0, ''], [round.status, round.err]
    assert_match(/\Aforwarded #{forwarded} to zeus\n/, round.out)
    assert_equal(waiting, not_forwarded.to_h { [it['id'], it.values_at('state', 'detail')] })
  end

  def test_a_batch_whose_checks_pass_zeuss_budget_arrives_one_message_per_round_each_checked_once
    slow_on_zeus
    first, second, third = three_in_one_thread
    behind = "zeus could not store it; it waits for #{second}, written before it in its thread"

    assert_round(first, second => ['queued', OUT_OF_TIME], third => ['queued', behind])
    assert_round(second, third => ['queued', OUT_OF_TIME])
    assert_round(third, {})
    assert_equal [first, second, third], slow.ids
    assert_equal([first, second, third], zeus.stored('port.dev').map { it.message.id })
    assert_empty store.outbox.queued('zeus')
  end
end
