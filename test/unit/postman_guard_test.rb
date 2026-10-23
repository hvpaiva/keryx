# frozen_string_literal: true

require 'test_helper'

class PostmanGuardTest < Minitest::Test
  include TempDir
  include Factory

  class WatchingBell
    def initialize(watch) = @watch = watch

    def ring(*)
      @watch.call(:bell)
      Keryx::Bell::Result.new(status: 'rung', channel: 'test', detail: nil, at: Factory::NOW)
    end
  end

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def zeus = @zeus ||= Keryx::Store.new(tmp('zeus'))

  # Whether another command found the occupants lock taken at each step of the post.
  def held = @held ||= {}

  def watch = @watch ||= ->(step) { held[step] = taken? }

  def taken?
    Thread.new do
      store.with_occupants_lock(within: 0) { false }
    rescue Keryx::Store::Busy
      true
    end.value
  end

  def remote
    @remote ||= FakeRemote.new do |_host, input|
      receiver = Keryx::Receiver.new(store: zeus, bell: WatchingBell.new(->(_) {}), host: 'zeus', person: 'person')
      input.each_line.map { "#{JSON.generate(receiver.receive(it))}\n" }.join
    end
  end

  def forwarder
    @forwarder ||= Keryx::Forwarder.new(store:, remote:, clock: -> { NOW }).tap do |forwarder|
      seen = watch
      forwarder.define_singleton_method(:forward) do |host|
        seen.call(:forward)
        super(host)
      end
    end
  end

  def postman
    Keryx::Postman.new(store:, bell: WatchingBell.new(watch), forwarder:, host: 'athena', clock: -> { NOW },
                       person: 'person')
  end

  def address(text) = Keryx::Address.parse(text, local_host: 'athena')

  def setup
    super
    store.create_address('rev-1')
    zeus.create_address('port')
    seen = watch
    store.define_singleton_method(:deliver) do |name, message|
      seen.call(:write)
      super(name, message)
    end
    store.outbox.define_singleton_method(:queue) do |host, message|
      seen.call(:write)
      super(host, message)
    end
  end

  def post(to, guard:) = postman.post(sender: 'orq', recipient: address(to), kind: 'message', body: 'hello', guard:)

  def asking(answer) = -> { watch.call(:guard).then { answer } }

  def test_a_guarded_post_writes_the_mailbox_in_the_guard_hold_and_rings_after_it
    posted = post('rev-1', guard: asking(true))

    assert_equal [posted.message], store.unread('rev-1')
    assert_equal({ guard: true, write: true, bell: false }, held)
  end

  def test_a_guarded_post_queues_for_another_machine_in_the_guard_hold_and_forwards_after_it
    posted = post('port@zeus', guard: asking(true))

    assert_equal 'forwarded', posted.forward.status
    assert_equal [posted.message], zeus.unread('port')
    assert_equal({ guard: true, write: true, forward: false }, held)
  end

  def test_a_post_without_a_guard_takes_no_lock
    post('rev-1', guard: nil)
    post('port@zeus', guard: nil)

    assert_equal({ write: false, bell: false, forward: false }, held)
  end

  def test_a_guard_that_says_no_writes_nothing_and_rings_or_forwards_nothing
    assert_nil post('rev-1', guard: asking(false))
    assert_nil post('port@zeus', guard: asking(nil))
    assert_empty store.unread('rev-1')
    assert_empty store.outbox.outgoing
    assert_empty remote.sent
    assert_equal({ guard: true }, held)
  end

  def test_a_guarded_post_the_other_machine_refuses_still_fails_and_is_not_kept
    error = assert_raises(Keryx::Error) { post('ghost@zeus', guard: asking(true)) }

    assert_equal 'zeus refused the message; no address ghost@zeus', error.message
    assert_empty store.outbox.outgoing
  end
end
