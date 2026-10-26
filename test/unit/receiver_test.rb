# frozen_string_literal: true

require 'test_helper'

class ReceiverTest < Minitest::Test
  include TempDir
  include Factory

  class FailingBell
    def ring(*) = raise Errno::ENOSPC, 'receipts'
  end

  class QuietBell
    def ring(*) = Keryx::Bell::Result.new(status: 'rung', channel: 'test', detail: nil, at: Factory::NOW)
  end

  class DeferredBell
    RESULT = Keryx::Bell::Result.new(status: 'deferred', channel: 'herdr', detail: 'a dialog', at: Factory::NOW,
                                     obstacle: :dialog, evidence: 'Do you trust the contents of this directory?')

    def ring(*) = RESULT
  end

  # A check like Keryx::Check whose every run takes 20 s of CLOCK under a timeout of 30 s, and records what it ran on.
  class SlowCheck
    attr_reader :calls

    def initialize(clock)
      @clock = clock
      @calls = []
    end

    def exempt?(message) = Keryx::Address.parse(message.from).key == Keryx::Identity::SYSTEM

    def timeout_for(message) = (30 unless exempt?(message))

    def refusal(message, event:, command:)
      @calls << [message.id, event, command]
      @clock.advance(20)
      nil
    end
  end

  def store = @store ||= Keryx::Store.new(tmp('zeus')).tap { it.create_address('port.dev') }

  def receive(message, bell: QuietBell.new)
    Keryx::Receiver.new(store:, bell:, host: 'zeus', person: 'person.local', check: Keryx::Check.new(host: 'zeus'))
                   .receive(message.to_json)
  end

  def incoming = @incoming ||= build_message(to: 'port.dev@zeus', from: 'orq.dev@athena')

  # The receipts a receiver on STORE gives for MESSAGES sent to it in one batch, as keryx __receive takes them.
  def batch(store, *messages)
    receipts = []
    receiver = Keryx::Receiver.new(store:, bell: QuietBell.new, host: 'zeus', person: 'person.local',
                                   check: Keryx::Check.new(host: 'zeus'))
    receiver.receive_all(StringIO.new(messages.map { "#{it.to_json}\n" }.join)) { receipts << it }
    receipts
  end

  def athena = @athena ||= Keryx::Store.new(tmp('athena')).tap { it.create_address('orq.dev') }

  def monotonic = @monotonic ||= CLIHelpers::Clock.new(0)

  def slow_check = @slow_check ||= SlowCheck.new(monotonic)

  # The receipts a receiver on athena gives for MESSAGES in one batch, each check there taking 20 s of its clock.
  def checked(*messages, live: ->(_name) {})
    receipts = []
    receiver = Keryx::Receiver.new(store: athena, bell: QuietBell.new, host: 'athena', person: 'person.local',
                                   check: slow_check, live:, monotonic:)
    receiver.receive_all(StringIO.new(messages.map { "#{it.to_json}\n" }.join)) { receipts << it }
    receipts
  end

  # A message from zeus written at AT, in a thread of its own.
  def from_zeus(to: 'orq.dev@athena', from: 'port.dev@zeus', at: NOW)
    build_message(to:, from:, id: Keryx::Ulid.generate(at))
  end

  def test_a_bell_that_fails_after_the_message_is_stored_still_reports_it_delivered
    receipt = receive(incoming, bell: FailingBell.new)

    assert_equal ['delivered', 'failed', 'No space left on device - receipts'],
                 [receipt['status'], receipt.dig('bell', 'status'), receipt.dig('bell', 'detail')]
    assert_equal [incoming], store.unread('port.dev')
  end

  # keryx __receive prints each receipt as a line of JSON, which Remote reads back on the sending machine.
  def test_a_deferred_bell_comes_back_to_the_sending_machine_with_its_obstacle_and_evidence
    lines = []
    receiver = Keryx::Receiver.new(store:, bell: DeferredBell.new, host: 'zeus', person: 'person.local',
                                   check: Keryx::Check.new(host: 'zeus'))
    receiver.receive_all(StringIO.new("#{incoming.to_json}\n")) { lines << "#{JSON.generate(it)}\n" }
    runner = FakeRunner.new({ ['ssh'] => { out: lines.join } })
    receipt = Keryx::Remote.new(runner:).deliver('zeus', [incoming]).receipts.fetch(incoming.id)

    assert_equal ['delivered', DeferredBell::RESULT.record], receipt.values_at('status', 'bell')
    assert_equal ['dialog', 'Do you trust the contents of this directory?'],
                 receipt['bell'].values_at('obstacle', 'evidence')
  end

  def test_mail_for_a_retired_address_is_refused_as_retired
    store.retire('port.dev', by: 'person.local@zeus', now: NOW)
    receipts = %w[message request reply].map { receive(build_message(to: 'port.dev@zeus', kind: it)) }

    assert_equal([{ 'status' => 'refused', 'detail' => 'port.dev@zeus is retired; mail to it is refused' }] * 3,
                 receipts.map { it.except('id') })
    assert_empty store.mailbox('port.dev')
  end

  # A request that reached the mailbox as the address was retired stays open on its sender's machine until its
  # withdrawal lands next to it.
  def test_a_withdrawal_reaches_its_request_in_a_retired_mailbox_and_no_other
    request = build_message(to: 'port.dev@zeus', kind: 'request')
    store.deliver('port.dev', request)
    store.retire('port.dev', by: 'person.local@zeus', now: NOW)
    withdrawal = ->(of) { build_message(to: 'port.dev@zeus', kind: 'withdrawal', in_reply_to: of, thread: of) }
    stray = Keryx::Ulid.generate

    assert_equal 'delivered', receive(withdrawal.call(request.id))['status']
    assert_equal 'refused', receive(withdrawal.call(stray))['status']
    refute(store.mailbox('port.dev').any? { it.message.in_reply_to == stray })
  end

  def test_a_numeric_id_thread_or_in_reply_to_is_refused_before_it_is_stored
    numeric = 12_345_678_901_234_567_890_123_456
    receiver = Keryx::Receiver.new(store:, bell: QuietBell.new, host: 'zeus', person: 'person.local',
                                   check: Keryx::Check.new(host: 'zeus'))
    receipts = %w[id thread in_reply_to].map do |field|
      receiver.receive(JSON.generate(JSON.parse(incoming.to_json).merge(field => numeric)))
    end

    assert_equal(%w[refused] * 3, receipts.map { it['status'] })
    assert_empty Dir.children(tmp('zeus', 'addresses', 'port.dev', 'mail'))
  end

  def test_a_body_over_the_limit_is_refused
    receipt = receive(build_message(to: 'port.dev@zeus', from: 'orq.dev@athena', body: 'x' * 65_537))

    assert_equal ['refused', 'the body is 65537 bytes and the limit is 65536'], receipt.values_at('status', 'detail')
    assert_empty store.unread('port.dev')
  end

  def test_a_line_over_the_frame_limit_is_refused_without_stopping_the_next
    huge = build_message(to: 'port.dev@zeus', from: 'orq.dev@athena', body: 'x' * Keryx::Receiver::FRAME_LIMIT)
    receiver = Keryx::Receiver.new(store:, bell: QuietBell.new, host: 'zeus', person: 'person.local',
                                   check: Keryx::Check.new(host: 'zeus'))
    receipts = []
    receiver.receive_all(StringIO.new("#{huge.to_json}\n#{incoming.to_json}\n")) { receipts << it }

    assert_equal([[huge.id, 'refused'], [incoming.id, 'delivered']], receipts.map { it.values_at('id', 'status') })
    assert_match(/larger than \d+ bytes/, receipts.first['detail'])
  end

  def test_a_store_that_cannot_write_answers_failed_so_the_sender_tries_again
    store.define_singleton_method(:deliver) { |*| raise Errno::ENOSPC, 'mail' }

    assert_equal 'failed', receive(incoming)['status']
  end

  def test_a_message_that_fails_holds_back_the_later_ones_of_its_thread_in_that_batch_only
    first = build_message(to: 'port.dev@zeus', id: Keryx::Ulid.generate(NOW))
    other = build_message(to: 'port.dev@zeus', id: Keryx::Ulid.generate(NOW + 1))
    later = build_message(to: 'port.dev@zeus', id: Keryx::Ulid.generate(NOW + 2), thread: first.thread,
                          in_reply_to: first.id)
    store.define_singleton_method(:deliver) do |name, message|
      raise Errno::ENOSPC, 'mail' if message.id == first.id

      super(name, message)
    end
    held_back = batch(store, first, other, later)

    assert_equal([[first.id, 'failed'], [other.id, 'delivered'], [later.id, 'failed']],
                 held_back.map { it.values_at('id', 'status') })
    assert_equal "it waits for #{first.id}, written before it in its thread", held_back.last['detail']
    assert_equal(%w[delivered delivered], batch(Keryx::Store.new(tmp('zeus')), first, later).map { it['status'] })
  end

  # The session leaves right after the first check saw it running, as a leave on this machine can.
  def test_a_session_that_leaves_after_the_checks_gets_no_mail
    store.bind('port.dev', build_occupant(session: 'abc123'))
    live = ->(_name) { store.with_occupants_lock { store.unbind('port.dev') }.then { true } }
    receiver = Keryx::Receiver.new(store:, bell: QuietBell.new, host: 'zeus', person: 'person.local', live:,
                                   check: Keryx::Check.new(host: 'zeus'))
    receipt = receiver.receive(build_message(to: 'port.dev@zeus/abc123').to_json)

    assert_equal ['refused', 'mail to port.dev@zeus/abc123 is refused: its session left; write to port.dev@zeus'],
                 receipt.values_at('status', 'detail')
    assert_empty store.mailbox('port.dev')
  end

  def test_mail_to_a_session_address_while_another_command_keeps_the_lock_answers_failed
    store.bind('port.dev', build_occupant(session: 'abc123'))
    now = NOW
    waiting = Keryx::Store.new(tmp('zeus'), clock: -> { now }, sleeper: ->(seconds) { now += seconds })
    receiver = Keryx::Receiver.new(store: waiting, bell: QuietBell.new, host: 'zeus', person: 'person.local',
                                   live: ->(_name) { true }, check: Keryx::Check.new(host: 'zeus'))
    receipt = File.open(tmp('zeus', 'occupants.lock'), File::RDWR | File::CREAT) do |file|
      file.flock(File::LOCK_EX)
      receiver.receive(build_message(to: 'port.dev@zeus/abc123').to_json)
    end

    assert_equal 'failed', receipt['status']
    assert_match(/occupants\.lock stayed locked by another keryx command for 15s/, receipt['detail'])
    assert_empty store.mailbox('port.dev')
  end

  # The first check ends at 20 s, and the second could end past the budget of 40 s, at 20 + 30 + 1 for its kill grace,
  # so it does not run. A notice from keryx needs no check and is still written.
  def test_once_a_check_could_pass_the_budget_of_the_batch_each_later_message_that_needs_one_fails_unchecked
    remote = (1..4).map { from_zeus(at: NOW + it) }
    notice = from_zeus(from: 'keryx.system@zeus', at: NOW + 5)
    receipts = checked(*remote, notice)

    assert_equal(%w[delivered failed failed failed delivered], receipts.map { it['status'] })
    assert_equal(['the check on athena ran out of time in this batch'] * 3, receipts[1..3].map { it['detail'] })
    assert_equal [remote.first, notice], athena.stored('orq.dev').map(&:message)
    assert_equal [[remote.first.id, 'receive', nil]], slow_check.calls
  end

  # A resend of what arrived needs no check, so a resent batch moves past it within the budget.
  def test_a_message_the_mailbox_holds_already_answers_duplicate_unchecked_at_a_stable_or_a_running_session_address
    athena.bind('orq.dev', build_occupant(session: 'abc123'))
    held = [from_zeus, from_zeus(to: 'orq.dev@athena/abc123', at: NOW + 1)]
    held.each { athena.deliver('orq.dev', it) }
    receipts = checked(*held, live: ->(_name) { true })

    assert_equal(held.map { { 'id' => it.id, 'status' => 'duplicate' } }, receipts)
    assert_empty slow_check.calls
    assert_equal held, athena.stored('orq.dev').map(&:message)
  end

  def test_a_resend_of_a_held_message_to_a_session_that_left_is_still_refused
    athena.bind('orq.dev', build_occupant(session: 'abc123'))
    held = from_zeus(to: 'orq.dev@athena/abc123')
    athena.deliver('orq.dev', held)
    athena.with_occupants_lock { athena.unbind('orq.dev') }
    receipts = checked(held, live: ->(_name) { true })

    assert_equal([[held.id, 'refused',
                   'mail to orq.dev@athena/abc123 is refused: its session left; write to orq.dev@athena']],
                 receipts.map { it.values_at('id', 'status', 'detail') })
    assert_empty slow_check.calls
    assert_equal [held], athena.stored('orq.dev').map(&:message)
  end
end
