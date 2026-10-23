# frozen_string_literal: true

require 'test_helper'

class ContextFiguresTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  SOCKET = '/h.sock'
  FIXTURES = File.expand_path('../fixtures/context', __dir__)
  DOT = [0xB7].pack('U')

  def setup
    super
    @orq = join_claude('orq', 111, role: 'orchestrator')
  end

  # The fixtures belong to session-1 and thread-1, and each line keryx reads must name the session it measures.
  def copy(fixture, session, *parts)
    path = tmp('home', *parts)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, File.read(File.join(FIXTURES, fixture)).gsub(/"(session|thread)-1"/, %("#{session}")))
  end

  def claude_transcript(pid)
    copy('claude-transcript.jsonl', "session-#{pid}", '.claude', 'projects', '-work', "session-#{pid}.jsonl")
  end

  def codex_rollout(thread)
    copy('codex-rollout.jsonl', thread, '.codex', 'sessions', '2026', '10', '22',
         "rollout-2026-10-22T17-00-00-#{thread}.jsonl")
  end

  def join_codex(name, thread)
    keryx('join', name, env: { 'CODEX_THREAD_ID' => thread })
    { 'CODEX_THREAD_ID' => thread }
  end

  def join_cursor(name, conversation, pane)
    herdr.put(SOCKET, pane, Keryx::Herdr::Agent.new(pane:, kind: 'cursor', status: 'idle', session: conversation))
    keryx('join', name, env: { 'CURSOR_CONVERSATION_ID' => conversation, 'HERDR_SOCKET_PATH' => SOCKET,
                               'HERDR_PANE_ID' => pane })
  end

  def who = keryx('who', '--all').out.lines.drop(1).to_h { it.strip.split(/ {3,}/).values_at(0, 4) }

  def who_json
    JSON.parse(keryx('who', '--all', '-o', 'json').out)['addresses'].to_h { [it['address'], it['context']] }
  end

  def test_who_shows_what_each_harness_reports_and_nothing_for_a_session_that_ended
    claude_transcript(111)
    join_codex('impl', 'thread-1')
    codex_rollout('thread-1')
    join_cursor('docs', 'conversation-1', 'w1:p3')
    herdr.footers[[SOCKET, 'w1:p3']] = "Claude Opus 5.5 300K Extra High #{DOT} 81.2%\n"
    join_claude('rev-1', 222)
    claude_transcript(222)
    alive.delete(222)

    assert_equal({ 'orq@athena' => '121k', 'impl@athena' => '137k/258k 53%', 'docs@athena' => '244k/300k 81%',
                   'rev-1@athena' => '-' }, who)
    assert_equal({ 'orq@athena' => { 'used' => 121_203, 'window' => nil },
                   'impl@athena' => { 'used' => 137_000, 'window' => 258_400 },
                   'docs@athena' => { 'used' => 243_600, 'window' => 300_000 }, 'rev-1@athena' => nil }, who_json)
  end

  def test_a_live_session_keryx_cannot_read_is_unknown
    join_codex('impl', 'thread-1')

    assert_equal 'unknown', who['impl@athena']
    assert_nil who_json['impl@athena']
  end

  def test_status_lists_the_context_of_each_address
    claude_transcript(111)
    output = keryx('status').out
    data = JSON.parse(keryx('status', '-o', 'json').out)

    assert_match(/^orq@athena\s+orchestrator\s+live\s+121k\s+0\s+0$/, output)
    assert_equal({ 'used' => 121_203, 'window' => nil }, data['addresses'].first['context'])
  end

  def inbox(env) = JSON.parse(keryx('inbox', '--all', '-o', 'json', env:).out)

  def stamps(env) = inbox(env).map { it['context'] }

  def test_a_message_carries_the_context_of_the_session_that_sent_it
    claude_transcript(111)
    rev = join_claude('rev-1', 222)
    keryx('ask', 'rev-1', 'Review PR #448', env: @orq)
    keryx('send', 'rev-1', 'heads-up', env: @orq)
    id = inbox(rev).first['id']

    assert_equal [{ 'used' => 121_203, 'window' => nil }] * 2, stamps(rev)
    assert_match(/^context +121k when sent$/, keryx('read', id, env: rev).out)
    keryx('withdraw', id, env: @orq)

    assert_equal({ 'used' => 121_203, 'window' => nil }, inbox(rev).last['context'])
  end

  def test_a_reply_from_codex_carries_the_window_too
    rev = join_codex('rev-1', 'thread-1')
    codex_rollout('thread-1')
    keryx('ask', 'rev-1', 'Review PR #448', env: @orq)
    keryx('reply', inbox(rev).first['id'], 'Approved', env: rev)
    reply = inbox(@orq).last

    assert_equal({ 'used' => 137_000, 'window' => 258_400 }, reply['context'])
    assert_match(%r{^context +137k/258k 53% when sent$}, keryx('read', reply['id'], env: @orq).out)
  end

  def test_a_person_or_a_session_acting_as_another_address_stamps_nothing
    claude_transcript(111)
    rev = join_claude('rev-1', 222)
    keryx('send', 'rev-1', 'from the keyboard')
    keryx('--as', 'orq', 'send', 'rev-1', 'as orq', env: rev)
    files = Dir[tmp('state', 'addresses', 'rev-1', 'mail', '*.json')]

    assert_equal [nil, nil], stamps(rev)
    assert_equal([false, false], files.map { JSON.parse(File.read(it)).key?('context') })
    refute_match(/^context/, keryx('read', env: rev).out)
  end

  def test_a_stamp_this_build_does_not_know_still_delivers_the_message
    message = build_message(from: 'orq@zeus', to: 'person@athena', body: 'from zeus')
    data = JSON.parse(message.to_json).merge('context' => { 'used' => 'lots' })
    receipt = JSON.parse(keryx('__receive', input: "#{JSON.generate(data)}\n").out)

    assert_equal 'delivered', receipt['status']
    assert_equal([['from zeus', nil]], inbox({}).map { it.values_at('body', 'context') })
  end

  def test_acting_as_an_address_stamps_nothing_even_for_ones_own_or_a_former_session_in_this_pane
    claude_transcript(111)
    keryx('--as', 'orq', 'send', 'person', 'as my own address', env: @orq)
    store.create_address('former')
    store.bind('former', build_occupant(harness: 'codex', session_id: 'thread-1', herdr_socket: SOCKET,
                                        herdr_pane: 'w1:p3'))
    codex_rollout('thread-1')
    herdr.put(SOCKET, 'w1:p3', Keryx::Herdr::Agent.new(pane: 'w1:p3', kind: 'codex', status: 'idle',
                                                       session: 'thread-2'))
    keryx('--as', 'former', 'send', 'person', 'as the former session',
          env: { 'CODEX_THREAD_ID' => 'thread-2', 'HERDR_SOCKET_PATH' => SOCKET, 'HERDR_PANE_ID' => 'w1:p3' })

    assert_equal([nil, nil], inbox({}).map { it['context'] })
  end

  def test_a_stamp_with_a_count_no_window_could_hold_is_dropped_and_the_message_kept
    message = build_message(from: 'orq@zeus', to: 'person@athena', body: 'from zeus')
    data = JSON.parse(message.to_json).merge('context' => { 'used' => 10**100, 'window' => 1 })
    keryx('__receive', input: "#{JSON.generate(data)}\n")

    assert_equal([['from zeus', nil]], inbox({}).map { it.values_at('body', 'context') })
    refute_match(/^context/, keryx('read', message.id).out)
  end
end
