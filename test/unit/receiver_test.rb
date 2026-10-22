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

  def store = @store ||= Keryx::Store.new(tmp('zeus')).tap { it.create_address('port') }

  def receive(message, bell: QuietBell.new)
    Keryx::Receiver.new(store:, bell:, host: 'zeus', person: 'person').receive(message.to_json)
  end

  def incoming = @incoming ||= build_message(to: 'port@zeus', from: 'orq@athena')

  def test_a_bell_that_fails_after_the_message_is_stored_still_reports_it_delivered
    receipt = receive(incoming, bell: FailingBell.new)

    assert_equal ['delivered', 'failed', 'No space left on device - receipts'],
                 [receipt['status'], receipt.dig('bell', 'status'), receipt.dig('bell', 'detail')]
    assert_equal [incoming], store.unread('port')
  end

  def test_a_body_over_the_limit_is_refused
    receipt = receive(build_message(to: 'port@zeus', from: 'orq@athena', body: 'x' * 65_537))

    assert_equal ['refused', 'the body is 65537 bytes and the limit is 65536'], receipt.values_at('status', 'detail')
    assert_empty store.unread('port')
  end

  def test_a_line_over_the_frame_limit_is_refused_without_stopping_the_next
    huge = build_message(to: 'port@zeus', from: 'orq@athena', body: 'x' * Keryx::Receiver::FRAME_LIMIT)
    receiver = Keryx::Receiver.new(store:, bell: QuietBell.new, host: 'zeus', person: 'person')
    receipts = []
    receiver.receive_all(StringIO.new("#{huge.to_json}\n#{incoming.to_json}\n")) { receipts << it }

    assert_equal([[huge.id, 'refused'], [incoming.id, 'delivered']], receipts.map { it.values_at('id', 'status') })
    assert_match(/larger than \d+ bytes/, receipts.first['detail'])
  end

  def test_a_store_that_cannot_write_answers_failed_so_the_sender_tries_again
    store.define_singleton_method(:deliver) { |*| raise Errno::ENOSPC, 'mail' }

    assert_equal 'failed', receive(incoming)['status']
  end
end
