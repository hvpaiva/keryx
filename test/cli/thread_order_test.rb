# frozen_string_literal: true

require 'test_helper'

# The messages of a thread reach the other machine in the order they were written, so a later one, such as the reply
# that ends the thread, never overtakes one that could not be stored there.
class ThreadOrderTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  class QuietBell
    def ring(*) = Keryx::Bell::Result.new(status: 'rung', channel: 'test', detail: nil, at: Factory::NOW)
  end

  def statuses = @statuses ||= []

  # zeus takes each batch through RECEIVER, as keryx __receive does, and AFTER sees each receipt it gives.
  def answered_by(receiver, &after)
    @remote = FakeRemote.new do |_host, input|
      out = +''
      receiver.receive_all(StringIO.new(input)) do |receipt|
        statuses << receipt['status']
        after&.call(receipt)
        out << "#{JSON.generate(receipt)}\n"
      end
      out
    end
  end

  def take_and_reply(request, env: {}, as: [])
    took = keryx('send', '--re', request.id, 'On it', *as, env:)
    clock.advance(1)
    replied = keryx('reply', request.id, 'Done', *as, env:)
    keryx('courier', '--once')
    [took, replied]
  end

  def assert_sent_in_order(zeus, name, replied)
    take, reply = zeus.stored(name).map(&:message).reject(&:request?)

    assert_equal(%w[message reply], [take, reply].map(&:kind))
    assert_equal([['zeus', [take.id]], ['zeus', [take.id, reply.id]], ['zeus', [take.id, reply.id]]], remote.sent)
    assert_equal(%w[failed failed failed delivered delivered], statuses)
    assert_includes replied.out, "it waits for #{take.id}, written before it in its thread"
    assert_empty store.outbox.queued('zeus')
  end

  # port.dev@zeus asked orq.dev@athena, which no session holds, for a review.
  def request_from_zeus(zeus)
    zeus.create_address('port.dev')
    store.create_address('orq.dev')
    build_message(from: 'port.dev@zeus', to: 'orq.dev@athena', kind: 'request').tap do |request|
      zeus.outbox.queue('athena', request)
      zeus.outbox.settle('athena', request.id, :forwarded)
      store.deliver('orq.dev', request)
    end
  end

  def fail_to_write(zeus, times)
    deliver = zeus.method(:deliver)
    zeus.define_singleton_method(:deliver) do |name, message|
      times -= 1
      raise Errno::ENOSPC, 'mail' unless times.negative?

      deliver.call(name, message)
    end
  end

  # zeus cannot write the first two messages it gets.
  def test_a_message_zeus_could_not_write_is_not_overtaken_by_the_reply_that_ends_its_thread
    zeus = Keryx::Store.new(tmp('zeus'))
    request = request_from_zeus(zeus)
    fail_to_write(zeus, 2)
    answered_by(Keryx::Receiver.new(store: zeus, bell: QuietBell.new, host: 'zeus', person: 'person.local',
                                    check: Keryx::Check.new(host: 'zeus')))
    took, replied = take_and_reply(request, as: ['--as', 'orq.dev'])

    assert_equal [0, 0], [took.status, replied.status]
    assert_sent_in_order(zeus, 'port.dev', replied)
  end

  # rev.dev@zeus asked orq.dev@athena from its session abc123.
  def session_request_from_zeus(zeus)
    zeus.create_address('rev.dev')
    zeus.bind('rev.dev', build_occupant(session: 'abc123'))
    request = build_message(from: 'rev.dev@zeus/abc123', to: 'orq.dev@athena', kind: 'request')
    store.deliver('orq.dev', request)
    request
  end

  # Another keryx command on zeus keeps occupants.lock until the reply comes.
  def test_a_message_that_found_the_lock_kept_is_not_overtaken_by_a_later_one_in_its_thread
    now = NOW
    zeus = Keryx::Store.new(tmp('zeus'), clock: -> { now }, sleeper: ->(seconds) { now += seconds })
    orq = join_claude('orq.dev', 111)
    request = session_request_from_zeus(zeus)
    receiver = Keryx::Receiver.new(store: zeus, bell: QuietBell.new, host: 'zeus', person: 'person.local',
                                   live: ->(_name) { true }, check: Keryx::Check.new(host: 'zeus'))
    File.open(tmp('zeus', 'occupants.lock'), File::RDWR | File::CREAT) do |lock|
      lock.flock(File::LOCK_EX)
      answered_by(receiver) { lock.flock(File::LOCK_UN) if remote.sent.size == 2 }
      took, replied = take_and_reply(request, env: orq)

      assert_equal [0, 0], [took.status, replied.status]
      assert_sent_in_order(zeus, 'rev.dev', replied)
    end
  end
end
