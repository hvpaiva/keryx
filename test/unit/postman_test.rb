# frozen_string_literal: true

require 'test_helper'

class PostmanTest < Minitest::Test
  include TempDir
  include Factory

  class RecordingBell
    attr_reader :rung

    def initialize = @rung = []

    def ring(name, messages)
      @rung << [name, messages.map(&:id)]
      Keryx::Bell::Result.new(status: 'rung', channel: 'test', detail: nil, at: Factory::NOW)
    end
  end

  class FailingBell
    def ring(*) = raise Errno::ENOSPC, 'receipts'
  end

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def bell = @bell ||= RecordingBell.new

  def zeus = @zeus ||= Keryx::Store.new(tmp('zeus'))

  def remote
    @remote ||= FakeRemote.new do |_host, input|
      receiver = Keryx::Receiver.new(store: zeus, bell: RecordingBell.new, host: 'zeus', person: 'person.local',
                                     check: Keryx::Check.new(host: 'zeus'))
      input.each_line.map { "#{JSON.generate(receiver.receive(it))}\n" }.join
    end
  end

  def forwarder = Keryx::Forwarder.new(store:, remote:, clock: -> { NOW })

  def postman
    Keryx::Postman.new(store:, bell:, forwarder:, host: 'athena', clock: -> { NOW }, person: 'person.local',
                       check: Keryx::Check.new(host: 'athena'))
  end

  def address(text) = Keryx::Resolver.new(store:, host: 'athena').resolve(text, sender: 'orq.dev')

  def setup
    super
    %w[orq.dev rev-1.dev].each { store.create_address(it) }
  end

  def test_post_delivers_then_rings
    posted = postman.post(sender: 'orq.dev', recipient: address('rev-1.dev'), kind: 'request', body: 'Review it',
                          due_at: NOW + 1800)

    assert_equal [posted.message], store.unread('rev-1.dev')
    assert_equal [['rev-1.dev', [posted.message.id]]], bell.rung
    assert_equal %w[orq.dev@athena rev-1.dev@athena request],
                 [posted.message.from, posted.message.to, posted.message.kind]
    assert_equal posted.message.id, posted.message.thread
  end

  def test_a_bell_that_fails_after_delivery_still_reports_the_message_sent
    failing = Keryx::Postman.new(store:, bell: FailingBell.new, forwarder:, host: 'athena', clock: -> { NOW },
                                 person: 'person.local', check: Keryx::Check.new(host: 'athena'))
    posted = failing.post(sender: 'orq.dev', recipient: address('rev-1.dev'), kind: 'message', body: 'hello')

    assert_equal [posted.message], store.unread('rev-1.dev')
    assert_equal ['failed', 'No space left on device - receipts'], [posted.bell.status, posted.bell.detail]
  end

  def test_a_reply_joins_the_thread_of_the_message_it_answers
    request = postman.post(sender: 'orq.dev', recipient: address('rev-1.dev'), kind: 'request',
                           body: 'Review it').message
    reply = postman.post(sender: 'rev-1.dev', recipient: address('orq.dev'), kind: 'reply', body: 'Done',
                         reply_to: request).message

    assert_equal request.id, reply.in_reply_to
    assert_equal request.thread, reply.thread
  end

  def test_a_message_posted_again_under_its_id_is_stored_and_rung_once
    id = Keryx::Ulid.generate(NOW)
    2.times { postman.post(sender: 'orq.dev', recipient: address('rev-1.dev'), kind: 'message', body: 'once', id:) }

    assert_equal [id], store.unread('rev-1.dev').map(&:id)
    assert_equal [['rev-1.dev', [id]]], bell.rung
  end

  def test_a_message_to_oneself_is_stored_without_a_bell
    posted = postman.post(sender: 'orq.dev', recipient: address('orq.dev'), kind: 'message', body: 'note')

    assert_nil posted.bell
    assert_empty bell.rung
  end

  def test_post_refuses_an_unknown_local_address
    error = assert_raises(Keryx::Error) do
      postman.post(sender: 'orq.dev', recipient: address('ghost.dev'), kind: 'message', body: 'x')
    end

    assert_match(/no address ghost.dev@athena/, error.message)
  end

  def test_post_refuses_a_retired_address_and_keeps_its_mailbox_as_it_was
    store.create_address('rev-1.dev')
    store.retire('rev-1.dev', by: 'orq.dev@athena', now: NOW)
    error = assert_raises(Keryx::Error) do
      postman.post(sender: 'orq.dev', recipient: address('rev-1.dev'), kind: 'request', body: 'Review it')
    end

    assert_equal 'rev-1.dev@athena is retired; mail to it is refused', error.message
    assert_empty store.mailbox('rev-1.dev')
  end

  def test_a_withdrawal_reaches_a_request_in_a_retired_mailbox
    store.create_address('rev-1.dev')
    request = build_message(to: 'rev-1.dev@athena', kind: 'request')
    store.deliver('rev-1.dev', request)
    store.retire('rev-1.dev', by: 'orq.dev@athena', now: NOW)
    postman.withdraw(request, holder: 'rev-1.dev', body: 'not needed')

    assert_equal [request.id], store.mailbox('rev-1.dev').map(&:message).select(&:withdrawal?).map(&:in_reply_to)
  end

  def test_a_message_for_another_machine_is_forwarded_and_kept_as_sent
    zeus.create_address('port.dev')
    posted = postman.post(sender: 'orq.dev', recipient: address('port.dev@zeus'), kind: 'request', body: 'Port it')

    assert_equal 'forwarded', posted.forward.status
    assert_equal [posted.message], zeus.unread('port.dev')
    assert_equal([[posted.message, :forwarded]], store.outbox.outgoing.map { [it.message, it.state] })
    assert_empty bell.rung
  end

  def courier_forwarding_after_queue(outbox)
    courier = Keryx::Forwarder.new(store: Keryx::Store.new(tmp('state')), remote:, clock: -> { NOW })
    outbox.define_singleton_method(:queue) do |host, message|
      super(host, message).tap { courier.forward(host) }
    end
  end

  def test_a_message_the_courier_forwards_first_is_still_reported_as_forwarded
    zeus.create_address('port.dev')
    courier_forwarding_after_queue(store.outbox)
    posted = postman.post(sender: 'orq.dev', recipient: address('port.dev@zeus'), kind: 'request', body: 'Port it')

    assert_equal %w[forwarded rung], [posted.forward.status, posted.forward.bell['status']]
    assert_equal [posted.message], zeus.unread('port.dev')
    assert_equal [:forwarded], store.outbox.outgoing.map(&:state)
  end

  def test_a_message_the_courier_saw_refused_first_still_fails
    courier_forwarding_after_queue(store.outbox)
    error = assert_raises(Keryx::Error) do
      postman.post(sender: 'orq.dev', recipient: address('ghost.dev@zeus'), kind: 'message', body: 'x')
    end

    assert_equal 'zeus refused the message; no address ghost.dev@zeus', error.message
    assert_empty store.outbox.outgoing
  end

  def failing_after(during)
    Object.new.tap do |slow|
      slow.define_singleton_method(:deliver) do |host, _messages|
        during.call(host)
        Keryx::Remote::Answer.new(receipts: {}, error: 'ssh: connection reset')
      end
    end
  end

  def courier = Keryx::Forwarder.new(store: Keryx::Store.new(tmp('state')), remote:, clock: -> { NOW })

  def test_an_attempt_that_fails_after_the_courier_delivered_keeps_the_delivery
    zeus.create_address('port.dev')
    late = Keryx::Forwarder.new(store:, remote: failing_after(->(host) { courier.forward(host) }), clock: -> { NOW })
    posted = Keryx::Postman.new(store:, bell:, forwarder: late, host: 'athena', clock: lambda {
      NOW
    }, person: 'person.local', check: Keryx::Check.new(host: 'athena'))
                           .post(sender: 'orq.dev', recipient: address('port.dev@zeus'), kind: 'message', body: 'once')

    assert_equal %w[forwarded rung], [posted.forward.status, posted.forward.bell['status']]
    assert_equal 'forwarded', store.outbox.receipt('zeus', posted.message.id)['status']
    assert_equal [:forwarded], store.outbox.outgoing.map(&:state)
    assert_equal 1, zeus.unread('port.dev').size
  end

  def test_a_late_failed_attempt_by_another_process_does_not_fool_the_sender
    zeus.create_address('port.dev')
    late = Keryx::Forwarder.new(store: Keryx::Store.new(tmp('state')),
                                remote: failing_after(->(host) { courier.forward(host) }), clock: -> { NOW })
    store.outbox.define_singleton_method(:queue) do |host, message|
      super(host, message).tap { late.forward(host) }
    end
    posted = postman.post(sender: 'orq.dev', recipient: address('port.dev@zeus'), kind: 'message', body: 'once')

    assert_equal 'forwarded', posted.forward.status
    assert_equal 'forwarded', store.outbox.receipt('zeus', posted.message.id)['status']
  end

  def test_a_message_the_other_machine_refuses_is_not_kept
    error = assert_raises(Keryx::Error) do
      postman.post(sender: 'orq.dev', recipient: address('ghost.dev@zeus'), kind: 'message', body: 'x')
    end

    assert_equal 'zeus refused the message; no address ghost.dev@zeus', error.message
    assert_empty store.outbox.outgoing
  end

  def test_a_message_for_a_machine_that_is_down_waits_and_goes_out_once
    zeus.create_address('port.dev')
    remote.down << 'zeus'
    posted = postman.post(sender: 'orq.dev', recipient: address('port.dev@zeus'), kind: 'message', body: 'later')

    assert_equal ['queued', 'ssh: connect to host zeus port 22: No route to host'],
                 [posted.forward.status, posted.forward.detail]
    remote.down.clear
    2.times { forwarder.forward('zeus') }

    assert_equal [posted.message], zeus.unread('port.dev')
    assert_equal [:forwarded], store.outbox.outgoing.map(&:state)
  end

  def test_post_refuses_empty_oversized_and_invalid_bodies
    post = ->(body) { postman.post(sender: 'orq.dev', recipient: address('rev-1.dev'), kind: 'message', body:) }

    assert_raises(Keryx::UsageError) { post.call("  \n") }
    assert_match(/limit is 65536/, assert_raises(Keryx::Error) { post.call('x' * 65_537) }.message)
    assert_match(/not valid UTF-8/, assert_raises(Keryx::Error) { post.call(+"\xFF".b) }.message)
    assert_empty store.unread('rev-1.dev')
  end
end
