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

  def copy(fixture, *parts)
    path = tmp('home', *parts)
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.cp(File.join(FIXTURES, fixture), path)
  end

  def claude_transcript(pid) = copy('claude-transcript.jsonl', '.claude', 'projects', '-work', "session-#{pid}.jsonl")

  def codex_rollout(thread)
    copy('codex-rollout.jsonl', '.codex', 'sessions', '2026', '10', '22', "rollout-2026-10-22T17-00-00-#{thread}.jsonl")
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

  def who = keryx('who').out.lines.drop(1).to_h { it.strip.split(/ {3,}/).values_at(0, 4) }

  def who_json = JSON.parse(keryx('who', '-o', 'json').out).to_h { [it['address'], it['context']] }

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
end
