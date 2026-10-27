# frozen_string_literal: true

require 'test_helper'

# No command fails on the outcomes lock: a forward leaves the message whose outcome it cannot repair waiting, and a
# read of the queue warns about a message from before team names it cannot move.
class OutcomesLockTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include OutboxLocks

  def test_a_send_to_another_machine_waits_for_another_messages_repair_and_succeeds
    first, _, orq = undecided_outcome
    clock.advance(1)
    began = clock.now
    sent = holding(outbox('outcomes.lock')) { in_time { keryx('send', 'port.dev@zeus', 'second', env: orq) } }
    waiting = JSON.parse(keryx('status', '-o', 'json').out)['not_forwarded'].map { it.values_at('id', 'detail') }

    assert_equal 0, sent.status
    assert_in_delta 15, clock.now - began, 0.5
    assert_equal [[first, format(Keryx::Forwarder::UNRECORDED, host: 'zeus')]], waiting
  end

  def test_status_waits_for_an_old_messages_repair_and_warns
    orq = join_claude('orq.dev', 111)
    message = undecided_old_message
    began = clock.now
    status = holding(lock = outbox('outcomes.lock')) { in_time { keryx('status', env: orq) } }

    assert_equal 0, status.status
    assert_in_delta 15, clock.now - began, 0.5
    assert_includes status.err, "warning: did not move #{message} to refused/: #{format(OutboxLocks::BUSY, lock)}"
  end

  def test_a_courier_round_waits_once_for_an_old_messages_repair_however_often_it_reads_the_queue
    message = undecided_old_message
    began = clock.now
    round = holding(outbox('outcomes.lock')) { in_time { keryx('courier', '--once') } }

    assert_equal 0, round.status
    assert_in_delta 15, clock.now - began, 0.5
    assert_path_exists message
  end

  def test_a_forward_waits_once_for_the_outcomes_lock_however_many_outcomes_need_repair
    first, _, orq = undecided_outcome
    ids = [first, another_undecided_outcome(orq)]
    began = clock.now
    round = holding(outbox('outcomes.lock')) { in_time { keryx('courier', '--once') } }

    assert_equal 0, round.status
    assert_in_delta 15, clock.now - began, 0.5
    assert_includes round.out, '2 message(s) wait for zeus'
    assert_equal ids.sort, store.outbox.queued('zeus').map(&:id).sort
  end

  def test_each_round_of_one_courier_waits_for_the_outcomes_lock_again
    undecided_outcome
    waited = holding(outbox('outcomes.lock')) { in_time { lock_waits_in_two_rounds } }

    assert_in_delta 30, waited, 0.5
  end

  private

  # A second message to port.dev@zeus whose outcome file holds no decision, written a second after the first.
  def another_undecided_outcome(orq)
    clock.advance(1)
    before = store.outbox.queued('zeus').map(&:id)
    remote.down << 'zeus'
    keryx('send', 'port.dev@zeus', 'again', env: orq)
    remote.down.clear
    id = (store.outbox.queued('zeus').map(&:id) - before).first
    File.write(outbox('receipts', "#{id}.outcome"), OutboxLocks::UNDECIDED)
    id
  end

  # Runs keryx courier, one process, for two rounds, and gives the seconds it slept waiting for a lock.
  def lock_waits_in_two_rounds
    terminal = Keryx::CLI::Terminal.new(out: StringIO.new, err: StringIO.new, env: base_env)
    waited = 0
    rounds = 0
    sleeper = lambda do |seconds|
      clock.advance(seconds)
      next waited += seconds if seconds == Keryx::Store::LOCK_POLL_SECONDS
      raise Interrupt if (rounds += 1) == 2
    end
    factory = lambda do |_globals|
      Keryx::App.new(env: terminal.env, herdr:, remote:, clock:, claude_socket: sockets, codex:, sleeper:, processes:)
    end
    Keryx.run(%w[courier], terminal:, app_factory: factory)
    waited
  end
end
