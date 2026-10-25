# frozen_string_literal: true

require 'test_helper'

# On this machine as from another, an address from before team names sends in a thread only what finishes a request
# still open.
class FlatThreadsTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include FlatAddresses

  # Here as from another machine, a reply ends the request, and a reply answers no reply.
  def test_a_flat_address_sends_nothing_more_here_in_a_thread_that_is_over
    unheld('orq')
    rev = held('rev-1', 222)
    request = flat_request(from: 'orq@athena', to: 'rev-1@athena')
    store.deliver('rev-1', request)
    keryx('reply', request.id, 'Done', env: rev)
    clock.advance(1)
    again = keryx('reply', request.id, 'Done again', env: rev)
    thanks = keryx('reply', store.mailbox('orq').first.message.id, 'Thanks', '--as', 'orq@athena')

    assert_equal [1, "error: #{flat_refusal('orq@athena', over: request.id)}\n"], [again.status, again.err]
    assert_equal [1, "error: #{flat_refusal('rev-1@athena')}\n"], [thanks.status, thanks.err]
    assert_equal(['Done'], store.mailbox('orq').map { it.message.body })
    assert_equal([request.id], store.mailbox('rev-1').map { it.message.id })
  end

  def test_a_flat_address_withdraws_its_open_request_here_and_the_thread_is_over
    unheld('orq')
    rev = held('rev-1', 222)
    request = flat_request(from: 'orq@athena', to: 'rev-1@athena')
    store.deliver('rev-1', request)
    clock.advance(1)
    withdrawn = keryx('withdraw', request.id, '--as', 'orq@athena')
    clock.advance(1)
    late = keryx('reply', request.id, 'Done', env: rev)

    assert_equal [0, ''], [withdrawn.status, withdrawn.err]
    assert_equal [1, "error: #{flat_refusal('orq@athena', over: request.id)}\n"], [late.status, late.err]
    assert_equal(%w[request withdrawal], store.mailbox('rev-1').map { it.message.kind })
    assert_empty store.mailbox('orq')
  end

  def test_a_second_reply_to_a_flat_address_elsewhere_is_refused_before_it_leaves
    asked, = flat_threads_on_zeus
    unheld('orq')
    store.deliver('orq', asked)
    replied = keryx('reply', asked.id, 'Done', '--as', 'orq@athena')
    clock.advance(1)
    again = keryx('reply', asked.id, 'Done again', '--as', 'orq@athena')

    assert_equal [0, 1], [replied.status, again.status]
    assert_equal "error: #{flat_refusal('port@zeus', over: asked.id)}\n", again.err
    assert_equal 1, remote.sent.size
    assert_equal(['Done'], Keryx::Store.new(tmp('zeus')).stored('port').map(&:message).select(&:reply?).map(&:body))
  end
end
