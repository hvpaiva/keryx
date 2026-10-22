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

  def postman = Keryx::Postman.new(store:, bell:, host: 'athena', clock: -> { NOW })

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

  def test_post_refuses_unknown_and_remote_addresses
    post = ->(to) { postman.post(sender: 'orq', recipient: address(to), kind: 'message', body: 'x') }

    assert_match(/no address ghost@athena/, assert_raises(Keryx::Error) { post.call('ghost') }.message)
    assert_match(/rev-1@zeus is on another machine/, assert_raises(Keryx::Error) { post.call('rev-1@zeus') }.message)
  end

  def test_post_refuses_empty_oversized_and_invalid_bodies
    post = ->(body) { postman.post(sender: 'orq', recipient: address('rev-1'), kind: 'message', body:) }

    assert_raises(Keryx::UsageError) { post.call("  \n") }
    assert_match(/limit is 65536/, assert_raises(Keryx::Error) { post.call('x' * 65_537) }.message)
    assert_match(/not valid UTF-8/, assert_raises(Keryx::Error) { post.call(+"\xFF".b) }.message)
    assert_empty store.unread('rev-1')
  end
end
