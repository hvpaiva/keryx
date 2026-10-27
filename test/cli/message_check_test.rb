# frozen_string_literal: true

require 'test_helper'

# Each command that writes a message runs athena's checker once on the message it then writes, and nothing when no
# check file exists.
class MessageCheckTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include MessageCheckHelpers

  def setup
    super
    @orq = join_claude('orq.dev', 111)
    @rev = join_claude('rev-1.dev', 222)
  end

  # orq asked rev-1.dev before any check file existed.
  def asked
    must(keryx('ask', 'rev-1.dev', 'Review PR #448', env: @orq))
    clock.advance(1)
    store.unread('rev-1.dev').first.id
  end

  def test_with_no_check_file_send_ask_and_reply_work_and_no_checker_runs
    checker('athena', status: 1, reason: REASON)
    sent = keryx('send', 'rev-1.dev', 'A note', env: @orq)
    clock.advance(1)
    id = asked
    replied = keryx('reply', id, 'Approved', env: @rev)

    assert_equal [0, 0], [sent.status, replied.status]
    assert_match(/\ASent \w{26} to rev-1.dev@athena\. The bell rang through claude\.\n\z/, sent.out)
    assert_match(/\AReplied to orq.dev@athena \(\w{26}\)\. The bell rang through claude\.\n/, replied.out)
    assert_equal([%w[message request], %w[reply]],
                 %w[rev-1.dev orq.dev].map { |name| store.stored(name).map { it.message.kind } })
    refute_path_exists record
  end

  def test_send_runs_the_checker_once_on_the_message_it_delivers
    accepting

    assert_checked(keryx('send', 'rev-1.dev', 'A note', env: @orq), 'send', 'rev-1.dev')
  end

  def test_ask_runs_the_checker_once_on_the_request_it_delivers
    accepting

    assert_checked(keryx('ask', 'rev-1.dev', 'Review it', '--within', '30m', env: @orq), 'ask', 'rev-1.dev')
  end

  def test_send_re_runs_the_checker_once_on_the_message_to_the_requests_sender
    id = asked
    accepting

    assert_checked(keryx('send', '--re', id, 'On it', env: @rev), 'send --re', 'orq.dev')
  end

  def test_send_on_runs_the_checker_once_on_the_message_to_the_requests_recipient
    id = asked
    accepting

    assert_checked(keryx('send', '--on', id, 'The fixture is reset', env: @orq), 'send --on', 'rev-1.dev')
  end

  def test_reply_runs_the_checker_once_on_the_reply_it_delivers
    id = asked
    accepting

    assert_checked(keryx('reply', id, 'Approved', env: @rev), 'reply', 'orq.dev')
  end

  def test_withdraw_runs_the_checker_once_on_the_withdrawal_it_delivers
    id = asked
    accepting

    assert_checked(keryx('withdraw', id, 'Fixed upstream', env: @orq), 'withdraw', 'rev-1.dev')
  end

  def test_a_checker_that_exits_2_fails_the_send
    check_with(path = checker('athena', status: 2, reason: 'cannot reach the tracker'))
    sent = keryx('send', 'rev-1.dev', 'A note', env: @orq)

    assert_equal [1, ''], [sent.status, sent.out]
    assert_equal "error: the check failed: #{path} exited with status 2: cannot reach the tracker\n", sent.err
    assert_empty store.stored('rev-1.dev')
  end

  def test_an_invalid_check_file_fails_the_send_without_running_the_checker
    check_with(checker('athena'), timeout: 31)
    sent = keryx('send', 'rev-1.dev', 'A note', env: @orq)

    assert_equal [1, ''], [sent.status, sent.out]
    assert_equal "error: the check failed: #{check_path}:2: timeout must be a whole number of seconds from 1 to 30, " \
                 "not \"31\"\n", sent.err
    assert_empty store.stored('rev-1.dev')
    refute_path_exists record
  end

  # Ruby would hand a checker without #! to /bin/sh, which would read it and accept, so it is refused unrun.
  def test_a_checker_without_a_header_fails_the_send_without_running
    path = real_tmp('athena-checker')
    File.write(path, "cat >> #{record}\nexit 0\n")
    File.chmod(0o755, path)
    check_with(path)
    sent = keryx('send', 'rev-1.dev', 'A note', env: @orq)

    assert_equal [1, '', "error: the check failed: the checker #{path} starts with neither #! nor an ELF or Mach-O " \
                         "header\n"], [sent.status, sent.out, sent.err]
    assert_empty store.stored('rev-1.dev')
    refute_path_exists record
  end

  def test_a_courier_reminder_for_an_overdue_request_is_delivered_past_a_refusing_checker
    must(keryx('ask', 'rev-1.dev', 'Review it', '--within', '1m', env: @orq))
    refusing
    clock.advance(120)
    courier = keryx('courier', '--once')
    notice = store.stored('orq.dev').map(&:message).first

    assert_equal [0, ''], [courier.status, courier.err]
    assert_match(/\Atold orq.dev@athena that \w{26} to rev-1.dev@athena is past its deadline\n/, courier.out)
    assert_equal 'keryx.system@athena', notice.from
    assert_match(/\ARequest \w{26} to rev-1.dev@athena passed its deadline without a reply\.\z/, notice.body)
    refute_path_exists record
  end

  def test_a_person_at_a_plain_terminal_sends_past_a_refusing_checker
    refusing
    sent = keryx('send', 'rev-1.dev', 'From the desk', env: { 'USER' => 'hvpaiva' })

    assert_equal [0, ''], [sent.status, sent.err]
    assert_equal([['hvpaiva.local@athena', 'From the desk']],
                 store.stored('rev-1.dev').map { it.message.then { |m| [m.from, m.body] } })
    refute_path_exists record
  end
end
