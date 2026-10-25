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

  def store = @store ||= Keryx::Store.new(tmp('zeus')).tap { it.create_address('port.dev') }

  def receive(message, bell: QuietBell.new)
    Keryx::Receiver.new(store:, bell:, host: 'zeus', person: 'person.local').receive(message.to_json)
  end

  def incoming = @incoming ||= build_message(to: 'port.dev@zeus', from: 'orq.dev@athena')

  # The receipts a receiver on STORE gives for MESSAGES sent to it in one batch, as keryx __receive takes them.
  def batch(store, *messages)
    receipts = []
    receiver = Keryx::Receiver.new(store:, bell: QuietBell.new, host: 'zeus', person: 'person.local')
    receiver.receive_all(StringIO.new(messages.map { "#{it.to_json}\n" }.join)) { receipts << it }
    receipts
  end

  def test_a_bell_that_fails_after_the_message_is_stored_still_reports_it_delivered
    receipt = receive(incoming, bell: FailingBell.new)

    assert_equal ['delivered', 'failed', 'No space left on device - receipts'],
                 [receipt['status'], receipt.dig('bell', 'status'), receipt.dig('bell', 'detail')]
    assert_equal [incoming], store.unread('port.dev')
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
    receiver = Keryx::Receiver.new(store:, bell: QuietBell.new, host: 'zeus', person: 'person.local')
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
    receiver = Keryx::Receiver.new(store:, bell: QuietBell.new, host: 'zeus', person: 'person.local')
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
    receiver = Keryx::Receiver.new(store:, bell: QuietBell.new, host: 'zeus', person: 'person.local', live:)
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
                                   live: ->(_name) { true })
    receipt = File.open(tmp('zeus', 'occupants.lock'), File::RDWR | File::CREAT) do |file|
      file.flock(File::LOCK_EX)
      receiver.receive(build_message(to: 'port.dev@zeus/abc123').to_json)
    end

    assert_equal 'failed', receipt['status']
    assert_match(/occupants\.lock stayed locked by another keryx command for 15s/, receipt['detail'])
    assert_empty store.mailbox('port.dev')
  end
end
