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

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def bell = @bell ||= RecordingBell.new

  def zeus = @zeus ||= Keryx::Store.new(tmp('zeus'))

  def remote
    @remote ||= FakeRemote.new do |_host, input|
      receiver = Keryx::Receiver.new(store: zeus, bell: RecordingBell.new, host: 'zeus', person: 'person')
      input.each_line.map { "#{JSON.generate(receiver.receive(it))}\n" }.join
    end
  end

  def forwarder = Keryx::Forwarder.new(store:, remote:, clock: -> { NOW })

  def postman = Keryx::Postman.new(store:, bell:, forwarder:, host: 'athena', clock: -> { NOW }, person: 'person')

  def address(text) = Keryx::Address.parse(text, local_host: 'athena')

  def setup
    super
    %w[orq rev-1].each { store.create_address(it) }
  end

  def test_post_delivers_then_rings
    posted = postman.post(sender: 'orq', recipient: address('rev-1'), kind: 'request', body: 'Review it',
                          due_at: NOW + 1800)

    assert_equal [posted.message], store.unread('rev-1')
    assert_equal [['rev-1', [posted.message.id]]], bell.rung
    assert_equal %w[orq@athena rev-1@athena request], [posted.message.from, posted.message.to, posted.message.kind]
    assert_equal posted.message.id, posted.message.thread
  end

  def test_a_reply_joins_the_thread_of_the_message_it_answers
    request = postman.post(sender: 'orq', recipient: address('rev-1'), kind: 'request', body: 'Review it').message
    reply = postman.post(sender: 'rev-1', recipient: address('orq'), kind: 'reply', body: 'Done',
                         reply_to: request).message

    assert_equal request.id, reply.in_reply_to
    assert_equal request.thread, reply.thread
  end

  def test_a_message_to_oneself_is_stored_without_a_bell
    posted = postman.post(sender: 'orq', recipient: address('orq'), kind: 'message', body: 'note')

    assert_nil posted.bell
    assert_empty bell.rung
  end

  def test_post_refuses_an_unknown_local_address
    error = assert_raises(Keryx::Error) do
      postman.post(sender: 'orq', recipient: address('ghost'), kind: 'message', body: 'x')
    end

    assert_match(/no address ghost@athena/, error.message)
  end

  def test_a_message_for_another_machine_is_forwarded_and_kept_as_sent
    zeus.create_address('port')
    posted = postman.post(sender: 'orq', recipient: address('port@zeus'), kind: 'request', body: 'Port it')

    assert_equal 'forwarded', posted.forward.status
    assert_equal [posted.message], zeus.unread('port')
    assert_equal([[posted.message, :forwarded]], store.outbox.outgoing.map { [it.message, it.state] })
    assert_empty bell.rung
  end

  def test_a_message_the_other_machine_refuses_is_not_kept
    error = assert_raises(Keryx::Error) do
      postman.post(sender: 'orq', recipient: address('ghost@zeus'), kind: 'message', body: 'x')
    end

    assert_equal 'zeus refused the message; no address ghost@zeus', error.message
    assert_empty store.outbox.outgoing
  end

  def test_a_message_for_a_machine_that_is_down_waits_and_goes_out_once
    zeus.create_address('port')
    remote.down << 'zeus'
    posted = postman.post(sender: 'orq', recipient: address('port@zeus'), kind: 'message', body: 'later')

    assert_equal ['queued', 'ssh: connect to host zeus port 22: No route to host'],
                 [posted.forward.status, posted.forward.detail]
    remote.down.clear
    2.times { forwarder.forward('zeus') }

    assert_equal [posted.message], zeus.unread('port')
    assert_equal [:forwarded], store.outbox.outgoing.map(&:state)
  end

  def test_post_refuses_empty_oversized_and_invalid_bodies
    post = ->(body) { postman.post(sender: 'orq', recipient: address('rev-1'), kind: 'message', body:) }

    assert_raises(Keryx::UsageError) { post.call("  \n") }
    assert_match(/limit is 65536/, assert_raises(Keryx::Error) { post.call('x' * 65_537) }.message)
    assert_match(/not valid UTF-8/, assert_raises(Keryx::Error) { post.call(+"\xFF".b) }.message)
    assert_empty store.unread('rev-1')
  end
end
