# frozen_string_literal: true

require 'test_helper'

class ForwarderTest < Minitest::Test
  include TempDir
  include Factory

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def forwarder(*statuses)
    remote = FakeRemote.new do |_host, input|
      id = JSON.parse(input.lines.first)['id']
      "#{JSON.generate('id' => id, 'status' => statuses.shift, 'detail' => 'No space left on device')}\n"
    end
    Keryx::Forwarder.new(store:, remote:, clock: -> { NOW })
  end

  def test_a_message_the_other_machine_failed_to_store_stays_queued_until_it_succeeds
    message = build_message(to: 'port@zeus')
    store.outbox.queue('zeus', message)
    forward = forwarder('failed', 'delivered')
    first = forward.forward('zeus').fetch(message.id)

    assert_equal ['queued', 'zeus could not store it; No space left on device'], [first.status, first.detail]
    assert_equal 1, store.outbox.receipt('zeus', message.id)['attempts']
    assert_equal 'forwarded', forward.forward('zeus').fetch(message.id).status
    assert_equal [:forwarded], store.outbox.outgoing.map(&:state)
  end

  def test_the_receipt_is_on_disk_before_the_message_leaves_new
    message = build_message(to: 'port@zeus')
    store.outbox.queue('zeus', message)
    store.outbox.define_singleton_method(:settle) { |*| raise Errno::EIO, 'outbox' }

    assert_raises(Errno::EIO) { forwarder('delivered').forward('zeus') }
    assert_equal 'forwarded', store.outbox.receipt('zeus', message.id)['status']
    assert_equal [:queued], store.outbox.outgoing.map(&:state)
  end
end
