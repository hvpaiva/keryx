# frozen_string_literal: true

require 'test_helper'

class OutboxTest < Minitest::Test
  include TempDir
  include Factory

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def outbox = store.outbox

  def test_the_outbox_queues_once_and_settles_each_message
    first = build_message(to: 'port@zeus', kind: 'request', id: Keryx::Ulid.generate(NOW))
    second = build_message(to: 'port@zeus', id: Keryx::Ulid.generate(NOW + 1))

    assert_equal %i[delivered duplicate delivered], [outbox.queue('zeus', first), outbox.queue('zeus', first),
                                                     outbox.queue('zeus', second)]
    assert outbox.settle('zeus', first.id, :forwarded)
    refute outbox.settle('zeus', first.id, :forwarded)
    outbox.settle('zeus', second.id, :refused)

    assert_equal([%w[zeus forwarded], %w[zeus refused]], outbox.outgoing.map { [it.host, it.state.to_s] })
    assert_equal([first.id], store.all_messages.map { it.last.message.id })
    assert_equal 0o700, File.stat(tmp('state', 'outbox', 'zeus', 'new')).mode & 0o777
  end

  def test_discard_removes_a_message_and_its_receipt_from_the_outbox
    message = build_message(to: 'port@zeus')
    outbox.queue('zeus', message)
    outbox.write_receipt('zeus', message.id, { 'status' => 'queued', 'attempts' => 1 })
    outbox.discard('zeus', message.id)

    assert_empty outbox.outgoing
    assert_nil outbox.receipt('zeus', message.id)
    assert_raises(Keryx::Error) { outbox.queue('../etc', message) }
  end
end
