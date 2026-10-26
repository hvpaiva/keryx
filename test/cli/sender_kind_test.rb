# frozen_string_literal: true

require 'test_helper'

# From rev-57's temporal_probe.rb, the review of pull request #46: what a bell says of its sender when it is rung again
# after the address changed hands, and when the sender's record cannot be opened.
class SenderKindTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def force_codex(seconds)
    clock.advance(seconds)
    result = keryx('join', 'orq.dev', '--force', env: { 'CODEX_THREAD_ID' => 'replacement' })

    assert_equal 0, result.status, result.err
  end

  def test_a_session_that_took_the_address_in_the_message_s_second_is_not_named_as_its_writer
    delayed_message
    force_codex(Rational(4, 10))

    assert_includes rung_again, 'from orq.dev@athena. Run '
  end

  def test_a_session_that_took_the_address_in_a_later_second_is_not_named_either
    delayed_message
    force_codex(1)

    assert_includes rung_again, 'from orq.dev@athena. Run '
  end

  def test_a_writer_that_left_is_its_address_alone
    sender = delayed_message

    assert_equal 0, keryx('leave', env: sender).status
    assert_includes rung_again, 'from orq.dev@athena. Run '
  end

  def test_a_displaced_session_that_writes_is_named_by_its_own_harness
    sender = join_claude('orq.dev', 111)
    join_claude('rev-1.dev', 222)
    original = store.occupant('orq.dev').session
    force_codex(1)
    clock.advance(Rational(1, 10))
    sent = keryx('send', 'rev-1.dev', 'the displaced Claude Code session writes', env: sender)

    assert_equal 0, sent.status, sent.err
    assert_includes sockets.posts.last.last, "from orq.dev@athena/#{original}, a Claude Code session. Run "
  end

  # The message is a second younger than orq.dev's join, so a record keryx could open would name its harness.
  def test_a_sender_record_keryx_cannot_open_leaves_its_address_alone_and_the_bell_still_rings
    skip 'root reads a file whatever its mode' if Process.uid.zero?
    join_claude('orq.dev', 111)
    join_claude('rev-1.dev', 222)
    path = tmp('state', 'addresses', 'orq.dev', 'occupant.json')
    message = build_message(to: 'rev-1.dev@athena', from: 'orq.dev@athena', kind: 'request', created_at: NOW + 1)
    store.deliver('rev-1.dev', message)
    File.chmod(0, path)
    result = Keryx::Bell.new(store:, herdr:, claude_socket: sockets, clock:).ring('rev-1.dev', [message])

    assert_equal 'rung', result.status
    assert_includes sockets.posts.last.last, 'from orq.dev@athena. Run '
  end

  private

  # orq.dev's Claude Code session writes to rev-1.dev a tenth of a second after both joined, while rev-1.dev's socket
  # is gone, so the bell waits for the courier to ring it again.
  def delayed_message
    sender = join_claude('orq.dev', 111)
    join_claude('rev-1.dev', 222)
    clock.advance(Rational(1, 10))
    sockets.gone << '/tmp/cc-222.sock'
    sent = keryx('send', 'rev-1.dev', 'written by Claude before the address changes hands', env: sender)
    message = store.unread('rev-1.dev').last

    assert_equal 0, sent.status, sent.err
    assert_equal 'failed', store.receipt('rev-1.dev', message.id, 'bell').fetch('status')
    sender
  end

  # The line the courier's next round posts to rev-1.dev's socket.
  def rung_again
    sockets.gone.clear
    round = keryx('courier', '--once')
    line = sockets.posts.select { it.first == '/tmp/cc-222.sock' }.last&.last

    assert_equal 0, round.status, round.err
    refute_nil line, round.out
    line
  end
end
