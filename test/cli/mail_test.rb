# frozen_string_literal: true

require 'test_helper'

class MailTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def setup
    super
    @orq = join_claude('orq', 111)
    @rev = join_claude('rev-1', 222)
  end

  def test_ask_delivers_a_request_and_rings_the_recipient_through_its_socket
    result = keryx('ask', 'rev-1', 'Review PR #448', '--within', '30m', env: @orq)
    id = last_id(@rev)

    assert_equal 0, result.status
    assert_match(/\AAsked rev-1@athena \(#{id}\)\. The bell rang through claude\.\nThe reply will ring this session/,
                 result.out)
    assert_equal [['/tmp/cc-222.sock', "[keryx] New request for rev-1@athena from orq@athena (#{id}). " \
                                       "Run 'keryx read #{id}' to open it."]], sockets.posts
  end

  def test_inbox_lists_unread_messages_with_their_deadline
    keryx('ask', 'rev-1', 'Review PR #448', '--within', '30m', env: @orq)
    clock.advance(600)
    keryx('send', 'rev-1', "FYI\nthe CI is green", env: @orq)
    rows = keryx('inbox', env: @rev).out.lines.map { it.split(/ {3,}/).map(&:strip) }

    assert_equal %w[ID KIND FROM AGE DUE SUMMARY], rows[0]
    assert_equal ['request', 'orq@athena', '10m', 'in 20m', 'Review PR #448'], rows[1][1..]
    assert_equal ['message', 'orq@athena', '0s', '-', 'FYI'], rows[2][1..]
  end

  def test_read_shows_the_message_marks_it_read_and_hints_the_reply
    keryx('ask', 'rev-1', "Review PR #448\n\nFocus on retries.", env: @orq)
    id = last_id(@rev)
    result = keryx('read', id[0, 8].downcase, env: @rev)

    assert_match(/\Aid +#{id}\nkind +request\nfrom +orq@athena\nto +rev-1@athena\nsent .*\n\nReview PR #448\n\n/,
                 result.out)
    assert_match(/Answer with: keryx reply #{id} TEXT\n\z/, result.out)
    assert_match(/No unread messages for rev-1@athena/, keryx('inbox', env: @rev).out)
  end

  def test_read_without_an_id_opens_the_oldest_unread
    keryx('send', 'rev-1', 'first', env: @orq)
    clock.advance(1)
    keryx('send', 'rev-1', 'second', env: @orq)

    assert_match(/\n\nfirst\n\z/, keryx('read', env: @rev).out)
    assert_match(/\n\nsecond\n\z/, keryx('read', env: @rev).out)
    assert_equal "No unread messages for rev-1@athena.\n", keryx('read', env: @rev).out
  end

  def test_read_neutralizes_terminal_escapes_in_the_body
    keryx('send', 'rev-1', "clear \e[2J screen", env: @orq)

    assert_includes keryx('read', env: @rev).out, 'clear ^[[2J screen'
  end

  def test_reply_answers_in_the_thread_and_wait_returns_it
    keryx('ask', 'rev-1', 'Review PR #448', env: @orq)
    id = last_id(@rev)
    replied = keryx('reply', id, 'Approved', env: @rev)

    assert_match(/\AReplied to orq@athena \(\w{26}\)\. The bell rang through claude\.\n\z/, replied.out)
    waited = keryx('wait', id, env: @orq)

    assert_equal 0, waited.status
    assert_match(/^reply to +#{id}$/, waited.out)
    assert_match(/\n\nApproved\n\z/, waited.out)
  end

  def test_wait_blocks_until_the_reply_arrives
    keryx('ask', 'rev-1', 'Review PR #448', env: @orq)
    id = last_id(@rev)
    replier = Thread.new { keryx('reply', id, 'Done', env: @rev) }
    replier.join

    assert_equal 0, keryx('wait', id[0, 10], '--timeout', '1m', env: @orq).status
  end

  def test_wait_times_out_with_status_three
    keryx('ask', 'rev-1', 'Review PR #448', env: @orq)
    id = last_id(@rev)
    started = clock.now
    result = keryx('wait', id, '--timeout', '90s', env: @orq)

    assert_equal 3, result.status
    assert_match(/no reply to #{id} from rev-1@athena yet/, result.err)
    assert_equal 90, clock.now - started
  end

  def test_wait_only_follows_requests_the_caller_sent
    keryx('send', 'rev-1', 'not a request', env: @orq)

    assert_match(/no request/, keryx('wait', last_id(@rev), env: @orq).err)
  end

  def test_the_body_can_come_from_a_file_or_standard_input
    File.write(tmp('brief.md'), "From a file\n")
    keryx('send', 'rev-1', '--file', tmp('brief.md'), env: @orq)
    clock.advance(1)
    keryx('send', 'rev-1', '-', env: @orq, input: "From stdin\n")
    summaries = JSON.parse(keryx('inbox', '-o', 'json', env: @rev).out).map { it['body'] }

    assert_equal ["From a file\n", "From stdin\n"], summaries
  end

  def test_the_body_must_come_from_exactly_one_place
    assert_equal 2, keryx('send', 'rev-1', 'text', '--file', 'x', env: @orq).status
    assert_match(/cannot read .*missing.md/, keryx('send', 'rev-1', '--file', tmp('missing.md'), env: @orq).err)
  end

  def test_sending_to_an_unknown_or_remote_address_fails
    assert_match(/no address ghost@athena/, keryx('send', 'ghost', 'x', env: @orq).err)
    assert_match(/rev-1@zeus is on another machine/, keryx('send', 'rev-1@zeus', 'x', env: @orq).err)
  end

  def test_a_person_at_a_terminal_sends_as_their_own_address
    result = keryx('send', 'rev-1', 'Please also check the docs')

    assert_equal 0, result.status
    assert_equal 'person@athena', JSON.parse(keryx('inbox', '-o', 'json', env: @rev).out).first['from']
  end

  def test_as_acts_as_another_address
    keryx('send', 'rev-1', 'hello', env: @orq)

    assert_equal 1, JSON.parse(keryx('--as', 'rev-1', 'inbox', '-o', 'json').out).size
    assert_equal 1, JSON.parse(keryx('inbox', '-o', 'json', env: { 'KERYX_AS' => 'rev-1' }).out).size
  end

  def test_a_bell_that_fails_leaves_the_message_waiting
    sockets.gone << '/tmp/cc-222.sock'
    result = keryx('send', 'rev-1', 'hello', env: @orq)

    assert_equal 0, result.status
    assert_match(%r{The bell failed \(socket /tmp/cc-222.sock: .*\); the message waits}, result.out)
    assert_equal 1, JSON.parse(keryx('inbox', '-o', 'json', env: @rev).out).size
  end

  def test_inbox_all_shows_read_messages_with_their_state
    keryx('send', 'rev-1', 'one', env: @orq)
    keryx('read', env: @rev)
    clock.advance(1)
    keryx('send', 'rev-1', 'two', env: @orq)
    states = keryx('inbox', '--all', env: @rev).out.lines.drop(1).map { it.split(/ {3,}/)[5] }

    assert_equal %w[read unread], states
  end
end
