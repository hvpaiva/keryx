# frozen_string_literal: true

require 'test_helper'

# Mail from another machine to a session address whose session left, which the holder of the address takes.
class DepartedSessionTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def setup
    super
    @impl = join_claude('impl.dev', 111)
    @address = "impl.dev@athena/#{store.occupant('impl.dev').session}"
    @orq = machine('zeus').merge(claude(222))
    alive << 222
    keryx('join', 'orq.dev', env: @orq)
  end

  def ask_then_leave
    asked = keryx('ask', @address, 'Review the change', env: @orq)
    raise "ask failed: #{asked.err}" unless asked.status.zero?

    keryx('leave', env: @impl)
    asked.out[/\(([0-9A-Z]{26})\)/, 1]
  end

  def status(env = {}) = JSON.parse(keryx('status', '--all', '-o', 'json', env:).out)

  def withdrawals = store.stored('impl.dev').map(&:message).select(&:withdrawal?)

  def test_a_withdrawal_from_another_machine_settles_at_a_session_address_whose_session_left
    id = ask_then_leave
    withdrawn = keryx('withdraw', id, env: @orq)

    assert_equal [0, ''], [withdrawn.status, withdrawn.err]
    assert_equal [id], withdrawals.map(&:in_reply_to)
    assert_empty status(@orq)['open_requests']
    assert_empty status['open_requests']
  end

  def test_a_withdrawal_that_waited_in_the_outbox_settles_there_once_it_arrives
    id = ask_then_leave
    remote.down << 'athena'

    assert_equal 0, keryx('withdraw', id, env: @orq).status

    remote.down.delete('athena')
    keryx('courier', '--once', env: @orq)

    assert_equal [id], withdrawals.map(&:in_reply_to)
    assert_empty status(@orq).values_at('open_requests', 'not_forwarded').flatten
  end

  # The request was answered here while zeus was down, so the address could retire before the reply reached its sender.
  def test_a_withdrawal_settles_there_after_the_address_is_retired
    id = ask_then_leave.tap { keryx('join', 'impl.dev', env: @impl) }
    remote.down << 'zeus'
    keryx('reply', id, 'Done', env: @impl)
    keryx('leave', env: @impl)

    assert_equal 0, keryx('retire', 'impl.dev').status

    withdrawn = keryx('withdraw', id, env: @orq)

    assert_equal [0, ''], [withdrawn.status, withdrawn.err]
    assert_equal [id], withdrawals.map(&:in_reply_to)
  end

  def test_other_mail_to_that_session_address_is_still_refused
    ask_then_leave
    sent = keryx('send', @address, 'Still there?', env: @orq)

    assert_equal [1, "error: athena refused the message; mail to #{@address} is refused: its session left; " \
                     "write to impl.dev@athena\n"], [sent.status, sent.err]
  end
end
