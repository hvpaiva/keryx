# frozen_string_literal: true

require 'test_helper'

# The messages of a thread written for another machine take ids in the order they were written, whatever the clock
# says, so the forwarder, which sends them in id order, sends them in that order.
class ThreadIdsTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  # rev.dev on zeus asks orq.dev here, and zeus is down from then on.
  def setup
    super
    @orq = join_claude('orq.dev', 111)
    @rev = machine('zeus').merge(claude(222))
    alive << 222
    keryx('join', 'rev.dev', env: @rev)
    keryx('ask', 'orq.dev@athena', 'Review the change', env: @rev)
    @request = store.stored('orq.dev').map(&:message).find(&:request?)
    remote.down << 'zeus'
  end

  def queued_bodies = store.outbox.queued('zeus').sort_by(&:id).map(&:body)

  def write(*bodies)
    bodies.each { keryx('send', '--re', @request.id, it, env: @orq) }
  end

  # A message of the thread under the id right after ID, which reached zeus and was moved to cur/ with its outcome.
  def forwarded_after(id)
    build_message(to: 'rev.dev@zeus', body: 'B', id: Keryx::Ulid.after(id), thread: @request.thread,
                  in_reply_to: @request.id).tap do |message|
      store.outbox.queue('zeus', message)
      store.outbox.write_outcome('zeus', message.id, { 'status' => Keryx::Forwarder::FORWARDED })
      store.outbox.settle('zeus', message.id, :forwarded)
    end
  end

  def test_messages_of_a_thread_written_in_one_millisecond_go_in_the_order_written
    write(*Array.new(10) { "Step #{it}" })
    keryx('reply', @request.id, 'Done', env: @orq)

    assert_equal [*Array.new(10) { "Step #{it}" }, 'Done'], queued_bodies
  end

  def test_a_reply_written_after_the_clock_went_back_still_goes_after
    write('On it')
    clock.advance(-5)
    keryx('reply', @request.id, 'Done', env: @orq)

    assert_equal ['On it', 'Done'], queued_bodies
  end

  def test_they_all_arrive_and_none_is_refused_once_zeus_is_back
    write(*Array.new(5) { "Step #{it}" })
    keryx('reply', @request.id, 'Done', env: @orq)
    remote.down.delete('zeus')
    keryx('courier', '--once')

    assert_empty JSON.parse(keryx('status', '-o', 'json').out)['not_forwarded']
    assert_equal(6, Keryx::Store.new(tmp('zeus')).stored('rev.dev').count { !it.message.request? })
  end

  # A waits in new/, B took the id right after A's and already reached zeus, and the clock is behind them both, so
  # the id after A's, the one C would take, is B's.
  def test_a_message_whose_turn_falls_on_an_id_that_left_the_outbox_goes_under_its_own
    write('A')
    gone = forwarded_after(store.outbox.queued('zeus').first.id)
    clock.advance(-5)
    sent = keryx('send', '--re', @request.id, 'C', env: @orq)
    id = sent.out[/Sent ([0-9A-Z]{26})/, 1]

    assert_equal %w[A C], queued_bodies
    assert_match 'waits in the outbox', sent.out
    assert_operator id, :>, gone.id
    assert_includes JSON.parse(keryx('status', '-o', 'json').out)['not_forwarded'].map { it.values_at('id', 'state') },
                    [id, 'queued']
    remote.down.delete('zeus')
    keryx('courier', '--once')

    assert_equal 'C', Keryx::Store.new(tmp('zeus')).stored('rev.dev').map(&:message).find { it.id == id }&.body
  end

  def test_a_withdrawal_written_in_the_millisecond_of_its_request_goes_after_it
    asked = keryx('ask', 'rev.dev@zeus', 'Check the docs', env: @orq)
    keryx('withdraw', asked.out[/\(([0-9A-Z]{26})\)/, 1], env: @orq)

    assert_equal %w[request withdrawal], store.outbox.queued('zeus').sort_by(&:id).map(&:kind)
  end
end
