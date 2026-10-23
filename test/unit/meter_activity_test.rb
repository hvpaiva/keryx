# frozen_string_literal: true

require 'test_helper'
require 'digest'

class MeterActivityTest < Minitest::Test
  include TempDir
  include Factory
  include MeterHelpers

  WRITTEN = Time.utc(2026, 10, 23, 12, 0, 0)

  def activity(**occupant) = meter.activity(build_occupant(cwd: '/work/repo.v1_0', **occupant))

  def written(path, time = WRITTEN)
    File.utime(time, time, path)
    path
  end

  def chats(cwd = '/work/repo.v1_0', id = 'conversation-1')
    tmp('home', '.cursor', 'chats', Digest::MD5.hexdigest(cwd), id)
  end

  def cursor_activity(**occupant) = activity(harness: 'cursor', session_id: 'conversation-1', **occupant)

  def test_claude_is_when_its_transcript_was_last_written
    written(transcript)

    assert_equal WRITTEN, activity
    recorded = written(put(tmp('home', '.claude', 'projects', 'x', 'session-1.jsonl'), ''), WRITTEN + 60)

    assert_equal WRITTEN + 60, activity(transcript: recorded)
  end

  def test_claude_has_no_activity_without_its_own_unlinked_transcript
    assert_nil activity
    outside = written(put(tmp('outside', 'session-1.jsonl'), ''))
    link(outside, tmp('home', '.claude', 'projects', SLUG, 'session-1.jsonl'))

    assert_nil activity
    assert_nil activity(session_id: '../session-1')
  end

  def test_codex_is_when_its_own_rollout_was_last_written
    written(rollout)

    assert_equal WRITTEN, activity(harness: 'codex', session_id: 'thread-1')
    written(rollout([meta('thread-2'), token_count('input_tokens' => 1000)].join("\n"), thread: 'thread-1'))

    assert_nil activity(harness: 'codex', session_id: 'thread-1')
  end

  def test_cursor_is_the_later_write_of_the_conversations_own_store
    database = written(put(File.join(chats, 'store.db'), ''), WRITTEN + 30)
    log = written(put(File.join(chats, 'store.db-wal'), ''))

    assert_equal WRITTEN + 30, cursor_activity
    written(log, WRITTEN + 90)

    assert_equal WRITTEN + 90, cursor_activity
    File.delete(database)

    assert_equal WRITTEN + 90, cursor_activity
  end

  def test_cursor_has_no_activity_without_its_own_conversation_store
    written(put(File.join(chats, 'store.db'), ''))

    assert_nil cursor_activity(session_id: 'conversation-2')
    assert_nil cursor_activity(session_id: nil)
    assert_nil cursor_activity(cwd: '/work/other')
    FileUtils.rm_rf(chats)
    link(written(put(tmp('outside', 'store.db'), '')), File.join(chats, 'store.db'))

    assert_nil cursor_activity
  end

  def test_a_session_keryx_cannot_read_has_no_activity_and_fails_nothing
    FileUtils.mkdir_p(File.join(chats, 'store.db'))

    assert_nil cursor_activity
    assert_nil activity(harness: 'aider')
    assert_nil meter.activity(nil)
    assert_nil activity(session_id: 42)
    env['HOME'] = 42

    assert_nil activity
  end
end
