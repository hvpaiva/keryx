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
    _, _, orq = undecided_outcome
    clock.advance(1)
    began = clock.now
    sent = holding(outbox('outcomes.lock')) { in_time { keryx('send', 'port.dev@zeus', 'second', env: orq) } }

    assert_equal 0, sent.status
    assert_in_delta 15, clock.now - began, 0.5
  end

  def test_status_waits_for_an_old_messages_repair_and_warns
    orq = join_claude('orq.dev', 111)
    message = undecided_old_message
    began = clock.now
    status = holding(lock = outbox('outcomes.lock')) { in_time { keryx('status', env: orq) } }

    assert_equal 0, status.status
    assert_in_delta 30, clock.now - began, 0.5
    assert_includes status.err, "warning: did not move #{message} to refused/: #{format(OutboxLocks::BUSY, lock)}"
  end
end
