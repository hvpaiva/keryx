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

  def test_a_store_that_cannot_write_answers_failed_so_the_sender_tries_again
    store.define_singleton_method(:deliver) { |*| raise Errno::ENOSPC, 'mail' }

    assert_equal 'failed', receive(incoming)['status']
  end
end
