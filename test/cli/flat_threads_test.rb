# frozen_string_literal: true

require 'test_helper'

# On this machine as from another, an address from before team names answers in its threads as it did before team
# names: a reply answers any message of the thread, whatever became of its request.
class FlatThreadsTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include FlatAddresses

  def test_a_flat_address_replies_here_in_a_thread_whose_request_is_answered
    unheld('orq')
    rev = held('rev-1', 222)
    request = flat_request(from: 'orq@athena', to: 'rev-1@athena')
    store.deliver('rev-1', request)
    keryx('reply', request.id, 'Done', env: rev)
    clock.advance(1)
    again = keryx('reply', request.id, 'Done again', env: rev)
    clock.advance(1)
    thanks = keryx('reply', store.mailbox('orq').first.message.id, 'Thanks', '--as', 'orq@athena')

    assert_equal([[0, ''], [0, '']], [again, thanks].map { [it.status, it.err] })
    assert_equal(['Done', 'Done again'], store.mailbox('orq').map { it.message.body })
    assert_equal(['Review PR #448', 'Thanks'], store.mailbox('rev-1').map { it.message.body })
  end

  def test_a_reply_after_a_flat_address_withdrew_its_request_is_still_delivered
    unheld('orq')
    rev = held('rev-1', 222)
    request = flat_request(from: 'orq@athena', to: 'rev-1@athena')
    store.deliver('rev-1', request)
    clock.advance(1)
    withdrawn = keryx('withdraw', request.id, '--as', 'orq@athena')
    clock.advance(1)
    late = keryx('reply', request.id, 'Done', env: rev)

    assert_equal([[0, ''], [0, '']], [withdrawn, late].map { [it.status, it.err] })
    assert_equal(%w[request withdrawal], store.mailbox('rev-1').map { it.message.kind })
    assert_equal(['Done'], store.mailbox('orq').map { it.message.body })
  end

  def test_a_second_reply_to_a_flat_address_elsewhere_goes
    asked, = flat_threads_on_zeus
    unheld('orq')
    store.deliver('orq', asked)
    replied = keryx('reply', asked.id, 'Done', '--as', 'orq@athena')
    clock.advance(1)
    again = keryx('reply', asked.id, 'Done again', '--as', 'orq@athena')

    assert_equal([[0, ''], [0, '']], [replied, again].map { [it.status, it.err] })
    assert_equal 2, remote.sent.size
    assert_equal(['Done', 'Done again'],
                 Keryx::Store.new(tmp('zeus')).stored('port').map(&:message).select(&:reply?).map(&:body))
  end
end
