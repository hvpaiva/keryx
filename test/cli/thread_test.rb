# frozen_string_literal: true

require 'test_helper'

class ThreadTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def setup
    super
    @orq = join_claude('orq', 111)
    @rev = join_claude('rev-1', 222)
    keryx('ask', 'rev-1', 'Review PR #448', env: @orq)
    @id = last_id(@rev)
    clock.advance(1)
  end

  def states = JSON.parse(keryx('status', '-o', 'json').out)['open_requests'].to_h { it.values_at('id', 'state') }

  def stop(env)
    keryx('hook', 'stop', env:, input: JSON.generate('session_id' => env['CLAUDE_CODE_SESSION_ID']))
  end

  def test_send_re_puts_a_message_in_the_thread_of_the_request_and_marks_it_read
    sent = keryx('send', '--re', @id, 'Taken; the PR comes within the hour', env: @rev)
    message = JSON.parse(keryx('inbox', '-o', 'json', env: @orq).out).last

    assert_equal 0, sent.status, sent.err
    assert_match(/\ASent (\w{26}) to orq@athena in the thread of #{@id}\. The bell rang through claude\.\n\z/,
                 sent.out)
    assert_equal ['message', @id, @id, 'rev-1@athena'], message.values_at('kind', 'thread', 'in_reply_to', 'from')
    assert_empty JSON.parse(keryx('inbox', '-o', 'json', env: @rev).out)
    assert_match(/^re +#{@id}$/, keryx('read', message['id'], env: @orq).out)
  end

  def test_a_request_its_recipient_sent_a_message_in_the_thread_of_is_taken_until_the_reply
    keryx('send', '--re', @id, 'Taken', env: @rev)

    assert_equal({ @id => 'taken' }, states)
    assert_match(/^#{@id} .* taken +Review PR #448$/, keryx('status').out)
    keryx('reply', @id, 'Approved', env: @rev)

    assert_empty states
  end

  def test_only_the_recipient_sends_in_the_thread_and_the_requesters_reply_there_settles_nothing
    assert_match(/no message #{@id} in the mailbox of orq/, keryx('send', '--re', @id, 'Mine', env: @orq).err)
    keryx('send', '--re', @id, 'Which branch?', env: @rev)
    keryx('reply', last_id(@orq), 'feat/retry', env: @orq)

    assert_equal ['feat/retry', @id], JSON.parse(keryx('inbox', '-o', 'json', env: @rev).out).last
                                          .values_at('body', 'thread')
    assert_equal({ @id => 'taken' }, states)
  end

  def test_the_stop_hook_does_not_remind_of_a_request_taken_in_its_thread
    keryx('ask', 'rev-1', 'Review PR #449', env: @orq)
    second = last_id(@rev)
    keryx('read', second, env: @rev)
    keryx('send', '--re', @id, 'Taken', env: @rev)
    reason = JSON.parse(stop(@rev).out)['reason']

    assert_match(/rev-1 has 1 request read but not answered \(#{second} from orq@athena\)\./, reason)
    refute_includes reason, @id
    assert_includes reason, "'keryx send --re ID TEXT'"
  end

  def test_a_taken_request_still_waits_for_its_answer
    keryx('send', '--re', @id, 'Taken', env: @rev)
    addresses = JSON.parse(keryx('status', '-o', 'json').out)['addresses']

    assert_equal([0, 1], addresses.map { it['waiting'] })
    assert_equal 3, keryx('wait', @id, '--timeout', '1s', env: @orq).status
    keryx('leave', env: @rev)

    assert_match(/rev-1@athena has 1 open request/, keryx('retire', 'rev-1').err)
  end

  def test_send_re_refuses_a_request_already_answered
    replied = keryx('reply', @id, 'Approved', env: @rev).out[/\w{26}/]
    result = keryx('send', '--re', @id, 'Taken', env: @rev)

    assert_equal 1, result.status
    assert_match(/#{@id} is already answered by #{replied}; .*'keryx send ADDRESS'/, result.err)
  end

  def test_send_re_refuses_a_withdrawn_request
    keryx('withdraw', @id, env: @orq)
    withdrawal = last_id(@rev)
    result = keryx('send', '--re', @id, 'Taken', env: @rev)

    assert_equal 1, result.status
    assert_match(/#{@id} is withdrawn by #{withdrawal}; .*'keryx send ADDRESS'/, result.err)
  end

  def test_send_re_takes_only_a_request
    keryx('send', 'rev-1', 'heads-up', env: @orq)
    result = keryx('send', '--re', last_id(@rev), 'Taken', env: @rev)

    assert_equal 1, result.status
    assert_match(/is a message, not a request; 'keryx reply ID' answers it in its thread/, result.err)
    assert_match(/no message 01ZZZZZZ in the mailbox of rev-1/, keryx('send', '--re', '01ZZZZZZ', 'x', env: @rev).err)
  end

  def test_send_re_takes_no_address_and_the_body_of_a_plain_send
    with_address = keryx('send', '--re', @id, 'orq', 'Taken', env: @rev)

    assert_equal 2, with_address.status
    assert_match(/--re sends to the request's sender; leave out ADDRESS/, with_address.err)
    assert_match(/missing the text/, keryx('send', '--re', @id, env: @rev).err)
    assert_match(/the message is empty/, keryx('send', '--re', @id, '-', input: " \n", env: @rev).err)
    assert_equal 0, keryx('send', '--re', @id, '-', input: "Taken\n", env: @rev).status
    assert_match(/missing ADDRESS/, keryx('send', env: @rev).err)
  end
end
