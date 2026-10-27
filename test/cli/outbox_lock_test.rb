# frozen_string_literal: true

require 'test_helper'

# The outbox's locks are waited for 15 seconds at most, as the occupants lock is, so a command stopped while it held
# one, or any other process that keeps the file, holds back no reply and no courier round for good.
class OutboxLockTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include OutboxLocks

  def test_a_reply_to_another_machine_gives_up_while_another_command_keeps_the_thread_lock
    orq, request = request_from_zeus

    assert_gives_up_on_the_thread_lock('reply', request.id, 'Done', env: orq) { assert_unread(request) }

    assert_equal([[request.thread, request.id]], store.outbox.queued('zeus').map { [it.thread, it.in_reply_to] })
  end

  def test_send_re_to_another_machine_gives_up_while_another_command_keeps_the_thread_lock
    orq, request = request_from_zeus

    assert_gives_up_on_the_thread_lock('send', '--re', request.id, 'On it', env: orq) { assert_unread(request) }

    assert_equal([[request.thread, 'message']], store.outbox.queued('zeus').map { [it.thread, it.kind] })
  end

  # Only a request still open takes send --on and withdraw, so the run once the lock is free shows it stayed open.
  def test_send_on_to_another_machine_gives_up_while_another_command_keeps_the_thread_lock
    orq, id = request_to_zeus

    assert_gives_up_on_the_thread_lock('send', '--on', id, 'One more thing', env: orq)

    assert_equal([[id, 'message']], store.outbox.queued('zeus').map { [it.thread, it.kind] })
  end

  def test_a_withdrawal_to_another_machine_gives_up_while_another_command_keeps_the_thread_lock
    orq, id = request_to_zeus

    assert_gives_up_on_the_thread_lock('withdraw', id, env: orq)

    assert_equal([[id, 'withdrawal']], store.outbox.queued('zeus').map { [it.in_reply_to, it.kind] })
  end

  def test_the_courier_leaves_a_message_waiting_while_another_command_keeps_the_outcomes_lock
    id, = undecided_outcome
    lock = outbox('outcomes.lock')
    began = clock.now
    round = holding(lock) { in_time { keryx('courier', '--once') } }

    assert_equal 0, round.status
    assert_includes round.out, "1 message(s) wait for zeus: #{format(Keryx::Forwarder::UNRECORDED, host: 'zeus')}"
    assert_in_delta 15, clock.now - began, 0.1
    assert_equal UNDECIDED, File.read(outbox('receipts', "#{id}.outcome"))
    assert_equal [id], store.outbox.queued('zeus').map(&:id)
  end

  def test_the_next_round_records_the_outcome_once_the_outcomes_lock_is_free
    id, port = undecided_outcome
    holding(outbox('outcomes.lock')) { in_time { keryx('courier', '--once') } }
    after = keryx('courier', '--once')

    assert_includes after.out, "forwarded #{id} to zeus"
    assert_equal 'forwarded', store.outbox.outcome('zeus', id)['status']
    assert_equal [['zeus', [id]], ['zeus', [id]]], remote.sent
    assert_equal([id], JSON.parse(keryx('inbox', '--all', '-o', 'json', env: port).out).map { it['id'] })
  end

  def test_an_old_message_stays_in_new_while_another_command_keeps_the_outcomes_lock
    message = undecided_old_message
    id = File.basename(message, '.json')
    lock = outbox('outcomes.lock')
    round = holding(lock) { in_time { keryx('courier', '--once') } }

    assert_equal 0, round.status
    assert_includes round.err, "warning: did not move #{message} to refused/: #{format(BUSY, lock)}"
    assert_path_exists message

    after = keryx('courier', '--once')

    assert_includes after.err, "warning: moved #{message} to refused/: message format 1"
    assert_path_exists outbox('refused', "#{id}.json")
    assert_equal 'refused', store.outbox.outcome('zeus', id)['status']
  end

  private

  # Runs ARGV while the test keeps thread.lock of zeus, which fails it with nothing queued and nothing sent, then
  # yields, then runs it again once the lock is free, with zeus unreachable so that what it wrote waits in new/.
  def assert_gives_up_on_the_thread_lock(*argv, env:)
    lock = outbox('thread.lock')
    sent = remote.sent.dup
    began = clock.now
    result = holding(lock) { in_time { keryx(*argv, env:) } }

    assert_equal [1, "error: #{format(BUSY, lock)}\n"], [result.status, result.err]
    assert_in_delta 15, clock.now - began, 0.1
    assert_empty Dir.children(outbox('new'))
    assert_equal sent, remote.sent
    yield if block_given?
    remote.down << 'zeus'

    assert_equal 0, keryx(*argv, env:).status
  end

  def assert_unread(request) = assert_includes(store.unread('orq.dev').map(&:id), request.id)

  # port.dev@zeus asked orq.dev, whose session runs here.
  def request_from_zeus
    orq = join_claude('orq.dev', 111)
    request = build_message(from: 'port.dev@zeus', to: 'orq.dev@athena', kind: 'request')
    store.deliver('orq.dev', request)
    [orq, request]
  end

  # orq.dev asked port.dev@zeus, which took the request.
  def request_to_zeus
    orq = join_claude('orq.dev', 111)
    zeus
    keryx('ask', 'port.dev@zeus', 'Review it', env: orq)
    [orq, Dir.children(outbox('cur')).first.delete_suffix('.json')]
  end
end
