# frozen_string_literal: true

require 'test_helper'

class ForwarderTest < Minitest::Test
  include TempDir
  include Factory

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def forwarder(*statuses)
    remote = FakeRemote.new do |_host, input|
      id = JSON.parse(input.lines.first)['id']
      "#{JSON.generate('id' => id, 'status' => statuses.shift, 'detail' => 'No space left on device')}\n"
    end
    Keryx::Forwarder.new(store:, remote:, clock: -> { NOW })
  end

  def test_a_message_the_other_machine_failed_to_store_stays_queued_until_it_succeeds
    message = build_message(to: 'port.dev@zeus')
    store.outbox.queue('zeus', message)
    forward = forwarder('failed', 'delivered')
    first = forward.forward('zeus').fetch(message.id)

    assert_equal ['queued', 'zeus could not store it; No space left on device'], [first.status, first.detail]
    assert_equal 1, store.outbox.receipt('zeus', message.id)['attempts']
    assert_equal 'forwarded', forward.forward('zeus').fetch(message.id).status
    assert_equal [:forwarded], store.outbox.outgoing.map(&:state)
  end

  def test_the_receipt_is_on_disk_before_the_message_leaves_new
    message = build_message(to: 'port.dev@zeus')
    store.outbox.queue('zeus', message)
    store.outbox.define_singleton_method(:settle) { |*| raise Errno::EIO, 'outbox' }

    assert_raises(Errno::EIO) { forwarder('delivered').forward('zeus') }
    assert_equal 'forwarded', store.outbox.receipt('zeus', message.id)['status']
    assert_equal [:queued], store.outbox.outgoing.map(&:state)
  end

  def answering(status, before: -> {})
    FakeRemote.new do |_host, input|
      before.call
      "#{JSON.generate('id' => JSON.parse(input.lines.first)['id'], 'status' => status, 'detail' => 'no address')}\n"
    end
  end

  def forwarding(remote, on: store) = Keryx::Forwarder.new(store: on, remote:, clock: -> { NOW })

  # Another process's attempt that writes its outcome and then stops until the test releases it.
  def start_paused_attempt(release)
    written = Queue.new
    other = Keryx::Store.new(tmp('state'))
    other.outbox.define_singleton_method(:write_outcome) do |*args|
      super(*args).tap do
        written << true
        release.pop
      end
    end
    @attempt = Thread.new { forwarding(answering('delivered'), on: other).forward('zeus') }
    written.pop
  end

  def test_an_attempt_refused_after_another_one_forwarded_moves_and_answers_by_the_forward
    request = build_message(to: 'port.dev@zeus', kind: 'request').tap { store.outbox.queue('zeus', it) }
    release = Queue.new
    remote = answering('refused', before: -> { start_paused_attempt(release) })
    second = forwarding(remote).forward('zeus').fetch(request.id)
    release << true
    open = Keryx::Roster.new(store:, herdr: FakeHerdr.new).open_requests.map { it.last.message.id }

    assert_equal %w[forwarded forwarded], [second.status, @attempt.value.fetch(request.id).status]
    assert_equal 'forwarded', store.outbox.outcome('zeus', request.id)['status']
    assert_equal [:forwarded], store.outbox.outgoing.map(&:state)
    assert_equal [request.id], open
  end

  def test_a_message_left_in_new_with_an_outcome_moves_by_it_without_being_sent_again
    forwarded, refused, waiting = Array.new(3) do |n|
      build_message(to: 'port.dev@zeus', id: Keryx::Ulid.generate(NOW + n)).tap { store.outbox.queue('zeus', it) }
    end
    store.outbox.write_outcome('zeus', forwarded.id, { 'status' => 'forwarded' })
    store.outbox.write_outcome('zeus', refused.id, { 'status' => 'refused', 'detail' => 'no address port.dev@zeus' })
    remote = answering('delivered')
    results = forwarding(remote).forward('zeus')

    assert_equal(%w[forwarded refused forwarded], [forwarded, refused, waiting].map { results.fetch(it.id).status })
    assert_equal [['zeus', [waiting.id]]], remote.sent
    assert_equal %i[forwarded refused forwarded], store.outbox.outgoing.map(&:state)
  end

  def test_an_outcome_whose_only_flaw_is_its_bell_moves_the_message_without_sending_it
    message = build_message(to: 'port.dev@zeus').tap { store.outbox.queue('zeus', it) }
    File.write(tmp('state', 'outbox', 'zeus', 'receipts', "#{message.id}.outcome"),
               JSON.generate('status' => 'forwarded', 'bell' => %w[wrong type]))
    remote = answering('delivered')
    result = forwarding(remote).forward('zeus').fetch(message.id)

    assert_equal ['forwarded', nil], [result.status, result.bell]
    assert_empty remote.sent
    assert_equal [:forwarded], store.outbox.outgoing.map(&:state)
  end

  def test_an_answer_with_a_status_keryx_does_not_know_writes_no_outcome
    message = build_message(to: 'port.dev@zeus').tap { store.outbox.queue('zeus', it) }

    assert_equal 'queued', forwarder('stored').forward('zeus').fetch(message.id).status
    assert_nil store.outbox.outcome('zeus', message.id)
    assert_equal [:queued], store.outbox.outgoing.map(&:state)
  end

  def test_an_interrupted_move_is_finished_by_the_next_forward
    message = build_message(to: 'port.dev@zeus').tap { store.outbox.queue('zeus', it) }
    store.outbox.define_singleton_method(:settle) { |*| raise Errno::EIO, 'outbox' }
    assert_raises(Errno::EIO) { forwarder('delivered').forward('zeus') }
    store.outbox.singleton_class.remove_method(:settle)
    remote = answering('refused')

    assert_equal 'forwarded', forwarding(remote).forward('zeus').fetch(message.id).status
    assert_empty remote.sent
    assert_equal [:forwarded], store.outbox.outgoing.map(&:state)
  end
end
