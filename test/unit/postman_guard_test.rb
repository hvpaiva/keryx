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
      receiver = Keryx::Receiver.new(store: zeus, bell: WatchingBell.new(lambda { |_|
      }), host: 'zeus', person: 'person.local', check: Keryx::Check.new(host: 'zeus'))
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

  def postman(**)
    Keryx::Postman.new(store:, bell: WatchingBell.new(watch), forwarder:, host: 'athena', clock: -> { NOW },
                       person: 'person.local', check: Keryx::Check.new(host: 'athena'), **)
  end

  def address(text) = Keryx::Resolver.new(store:, host: 'athena').resolve(text, sender: 'orq.dev')

  def setup
    super
    store.create_address('rev-1.dev')
    zeus.create_address('port.dev')
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

  # Only a sender the check exempts posts with a claim, as keryx's courier does.
  def post(to, claim:, sender: Keryx::Identity::SYSTEM)
    postman.post(sender:, recipient: address(to), kind: 'message', body: 'hello', claim:)
  end

  def claiming(id) = -> { watch.call(:claim).then { id } }

  def test_a_claimed_post_writes_the_mailbox_under_the_claimed_id_in_the_claim_hold_and_rings_after_it
    id = Keryx::Ulid.generate(NOW)
    posted = post('rev-1.dev', claim: claiming(id))

    assert_equal [id, [posted.message]], [posted.message.id, store.unread('rev-1.dev')]
    assert_equal({ claim: true, write: true, bell: false }, held)
  end

  def test_a_claimed_post_queues_for_another_machine_in_the_claim_hold_and_forwards_after_it
    id = Keryx::Ulid.generate(NOW)
    posted = post('port.dev@zeus', claim: claiming(id))

    assert_equal ['forwarded', id], [posted.forward.status, posted.message.id]
    assert_equal [posted.message], zeus.unread('port.dev')
    assert_equal({ claim: true, write: true, forward: false }, held)
  end

  def test_a_post_without_a_claim_takes_no_lock
    post('rev-1.dev', claim: nil, sender: 'orq.dev')
    post('port.dev@zeus', claim: nil, sender: 'orq.dev')

    assert_equal({ write: false, bell: false, forward: false }, held)
  end

  def test_a_claim_that_gives_no_id_writes_nothing_and_rings_or_forwards_nothing
    assert_nil post('rev-1.dev', claim: claiming(false))
    assert_nil post('port.dev@zeus', claim: claiming(nil))
    assert_empty store.unread('rev-1.dev')
    assert_empty store.outbox.outgoing
    assert_empty remote.sent
    assert_equal({ claim: true }, held)
  end

  def test_a_post_to_a_session_address_writes_in_the_hold_that_checks_the_session_with_or_without_a_claim
    store.bind('rev-1.dev', build_occupant(session: 'abc123'))
    session = Keryx::Address.parse('rev-1.dev@athena/abc123')
    bound = postman(live: ->(_name) { true })
    bound.post(sender: 'orq.dev', recipient: session, kind: 'message', body: 'hello')
    bound.post(sender: Keryx::Identity::SYSTEM, recipient: session, kind: 'message', body: 'hello',
               claim: claiming(Keryx::Ulid.generate))

    assert_equal 2, store.unread('rev-1.dev').size
    assert_equal({ write: true, bell: false, claim: true }, held)
  end

  # Measuring the sender's context comes after the checks and before the write, so a leave then comes between them.
  def test_a_session_that_leaves_after_the_checks_of_a_post_gets_no_mail_and_asks_no_claim
    session = Keryx::Address.parse('rev-1.dev@athena/abc123')
    leave = ->(_name) { store.with_occupants_lock { store.unbind('rev-1.dev') } }
    leaving = postman(live: ->(_name) { true }, measure: leave)
    errors = [['orq.dev', nil], [Keryx::Identity::SYSTEM, claiming(Keryx::Ulid.generate)]].map do |sender, claim|
      store.bind('rev-1.dev', build_occupant(session: 'abc123'))
      assert_raises(Keryx::Error) { leaving.post(sender:, recipient: session, kind: 'message', body: 'hello', claim:) }
    end

    assert_equal ['mail to rev-1.dev@athena/abc123 is refused: its session left; write to rev-1.dev@athena'] * 2,
                 errors.map(&:message)
    assert_empty store.mailbox('rev-1.dev')
    assert_empty held
  end

  def test_a_claimed_post_the_other_machine_refuses_still_fails_and_is_not_kept
    error = assert_raises(Keryx::Error) { post('ghost.dev@zeus', claim: claiming(Keryx::Ulid.generate(NOW))) }

    assert_equal 'zeus refused the message; no address ghost.dev@zeus', error.message
    assert_empty store.outbox.outgoing
  end

  # A claim holds the occupants lock, so a post that needs the check may not claim, and the checker never runs there.
  def test_a_claimed_post_from_a_sender_the_check_does_not_exempt_raises_before_any_claim_or_write
    errors = %w[rev-1.dev port.dev@zeus].map do |to|
      assert_raises(ArgumentError) { post(to, claim: claiming(Keryx::Ulid.generate(NOW)), sender: 'orq.dev') }
    end

    assert_equal ['only a sender the check exempts posts with a claim'] * 2, errors.map(&:message)
    assert_empty held
    assert_empty store.unread('rev-1.dev')
    assert_empty store.outbox.outgoing
  end
end
