# frozen_string_literal: true

require 'test_helper'

class WithdrawalsTest < Minitest::Test
  include TempDir
  include Factory

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def withdrawal(request, from:, id:)
    build_message(to: request.to, from:, kind: 'withdrawal', in_reply_to: request.id, thread: request.thread, id:)
  end

  def test_a_request_is_withdrawn_by_a_withdrawal_from_its_own_sender_read_or_not
    store.create_address('rev-1')
    request, other = [1, 2].map { build_message(to: 'rev-1@athena', kind: 'request', id: Keryx::Ulid.generate(NOW + it)) }
    pulled = withdrawal(request, from: 'orq@athena', id: Keryx::Ulid.generate(NOW + 3))
    forged = withdrawal(other, from: 'eve@athena', id: Keryx::Ulid.generate(NOW + 4))
    [request, other, pulled, forged].each { store.deliver('rev-1', it) }
    store.mark_read('rev-1', pulled.id)

    assert_equal({ request.id => pulled }, store.withdrawals('rev-1', store.unread('rev-1')))
    assert_empty store.withdrawals('rev-1', [pulled, forged])
  end
end
