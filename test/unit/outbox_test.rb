# frozen_string_literal: true

require 'test_helper'

class OutboxTest < Minitest::Test
  include TempDir
  include Factory

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def outbox = store.outbox

  # Only the messages of the same thread still waiting in new/ count.
  def test_a_message_of_a_thread_gets_the_last_id_of_its_thread_still_queued
    first = build_message(to: 'port.dev@zeus', kind: 'request', id: Keryx::Ulid.generate(NOW + 2))
    sent = build_message(to: 'port.dev@zeus', thread: first.thread, id: Keryx::Ulid.generate(NOW + 3))
    other = build_message(to: 'port.dev@zeus', kind: 'request', id: Keryx::Ulid.generate(NOW + 9))
    [first, sent, other].each { outbox.queue('zeus', it) }
    outbox.settle('zeus', sent.id, :forwarded)
    seen = []
    queued = [first.thread, Keryx::Ulid.generate(NOW + 20)].map do |thread|
      outbox.queue_in_thread('zeus', thread) { (seen << it).then { build_message(to: 'port.dev@zeus', thread:) } }
    end

    assert_equal [first.id, nil], seen
    assert_empty queued.map(&:id) - outbox.queued('zeus').map(&:id)
  end

  # The id after the last one in new/ can be taken by a message that left it, and the block then chooses after that.
  def test_a_message_of_a_thread_whose_id_is_taken_is_given_one_after_it
    waiting = build_message(to: 'port.dev@zeus', kind: 'request', id: Keryx::Ulid.generate(NOW))
    gone = build_message(to: 'port.dev@zeus', thread: waiting.thread, id: Keryx::Ulid.after(waiting.id))
    [waiting, gone].each { outbox.queue('zeus', it) }
    outbox.settle('zeus', gone.id, :forwarded)
    seen = []
    queued = outbox.queue_in_thread('zeus', waiting.thread) do |last|
      seen << last
      build_message(to: 'port.dev@zeus', thread: waiting.thread, body: 'next', id: Keryx::Ulid.after(last))
    end

    assert_equal [waiting.id, gone.id], seen
    assert_equal([[waiting.id, 'hello'], [Keryx::Ulid.after(gone.id), 'next']],
                 outbox.queued('zeus').sort_by(&:id).map { [it.id, it.body] })
    assert_equal Keryx::Ulid.after(gone.id), queued.id
  end

  def test_the_outbox_queues_once_and_settles_each_message
    first = build_message(to: 'port.dev@zeus', kind: 'request', id: Keryx::Ulid.generate(NOW))
    second = build_message(to: 'port.dev@zeus', id: Keryx::Ulid.generate(NOW + 1))

    assert_equal %i[delivered duplicate delivered], [outbox.queue('zeus', first), outbox.queue('zeus', first),
                                                     outbox.queue('zeus', second)]
    assert outbox.settle('zeus', first.id, :forwarded)
    refute outbox.settle('zeus', first.id, :forwarded)
    outbox.settle('zeus', second.id, :refused)

    assert_equal([%w[zeus forwarded], %w[zeus refused]], outbox.outgoing.map { [it.host, it.state.to_s] })
    assert_equal([first.id], store.all_messages.map { it.last.message.id })
    assert_equal 0o700, File.stat(tmp('state', 'outbox', 'zeus', 'new')).mode & 0o777
  end

  def test_discard_removes_a_message_and_its_receipt_from_the_outbox
    message = build_message(to: 'port.dev@zeus')
    outbox.queue('zeus', message)
    outbox.write_receipt('zeus', message.id, { 'status' => 'queued', 'attempts' => 1 })
    outbox.discard('zeus', message.id)

    assert_empty outbox.outgoing
    assert_nil outbox.receipt('zeus', message.id)
    assert_raises(Keryx::Error) { outbox.queue('../etc', message) }
  end

  def queued(at = NOW)
    build_message(to: 'port.dev@zeus', id: Keryx::Ulid.generate(at)).tap { outbox.queue('zeus', it) }
  end

  def outcome_file(id) = tmp('state', 'outbox', 'zeus', 'receipts', "#{id}.outcome")

  def forwarded = { 'status' => 'forwarded' }

  def test_an_outcome_keeps_its_decision_without_its_fields_of_the_wrong_type
    id = queued.id
    File.write(outcome_file(id), JSON.generate('status' => 'forwarded', 'detail' => 7, 'bell' => %w[wrong type],
                                               'at' => '2026-10-22T17:00:00Z'))
    outbox.write_outcome('zeus', id, { 'status' => 'refused' })

    assert_equal({ 'status' => 'forwarded', 'at' => '2026-10-22T17:00:00Z' }, outbox.outcome('zeus', id))
    assert_equal(%w[detail bell].map { "#{outcome_file(id)} has a bad #{it}; keryx reads the outcome without it" },
                 store.problems.uniq)
  end

  def test_an_outcome_with_no_decision_is_replaced_once
    ids = ['not json', '[]', '{"status": "queued"}'].each_with_index.map do |text, n|
      queued(NOW + n).id.tap { File.write(outcome_file(it), text) }
    end

    assert_equal([nil] * 3, ids.map { outbox.outcome('zeus', it) })
    assert_match(/#{ids[2]}\.outcome has a bad status; it is ignored until keryx writes it again/, store.problems[2])
    ids.each { |id| [forwarded, { 'status' => 'refused' }].each { outbox.write_outcome('zeus', id, it) } }

    assert_equal(%w[forwarded] * 3, ids.map { outbox.outcome('zeus', it)['status'] })
  end

  def test_a_repair_that_waited_its_turn_keeps_the_decision_another_one_wrote
    id = queued.id
    File.write(outcome_file(id), '[]')
    other = Keryx::Store.new(tmp('state')).outbox
    checks = 0
    outbox.define_singleton_method(:outcome) do |*args|
      super(*args).tap { other.write_outcome(*args, { 'status' => 'forwarded' }) if (checks += 1) == 1 }
    end
    outbox.write_outcome('zeus', id, { 'status' => 'refused' })

    assert_equal 'forwarded', other.outcome('zeus', id)['status']
  end

  def test_only_a_repair_takes_the_outcomes_lock
    fresh = queued
    damaged = queued(NOW + 1).tap { File.write(outcome_file(it.id), '[]') }
    File.open(tmp('state', 'outbox', 'zeus', 'outcomes.lock'), File::RDWR | File::CREAT) do |lock|
      lock.flock(File::LOCK_EX)

      assert Thread.new { outbox.write_outcome('zeus', fresh.id, forwarded) }.join(5)
      repair = Thread.new { outbox.write_outcome('zeus', damaged.id, forwarded) }

      assert_nil repair.join(0.2)
      lock.flock(File::LOCK_UN)

      assert repair.join(5)
    end
    assert_equal 'forwarded', outbox.outcome('zeus', damaged.id)['status']
  end

  def test_a_host_folder_that_is_a_symbolic_link_is_skipped
    elsewhere = Keryx::Store.new(tmp('elsewhere'))
    message = build_message(to: 'port.dev@zeus')
    elsewhere.outbox.queue('zeus', message)
    elsewhere.outbox.write_outcome('zeus', message.id, { 'status' => 'forwarded' })
    FileUtils.mkdir_p(tmp('state', 'outbox'))
    File.symlink(tmp('elsewhere', 'outbox', 'zeus'), tmp('state', 'outbox', 'zeus'))

    assert_empty outbox.hosts
    assert_empty outbox.outgoing
    assert_empty outbox.queued('zeus')
    assert_nil outbox.outcome('zeus', message.id)
    linked = tmp('state', 'outbox', 'zeus')

    assert_equal ["skipped #{linked}: a symbolic link",
                  "#{linked} is a symbolic link; it is ignored until keryx writes it again"], store.problems.uniq
  end
end
