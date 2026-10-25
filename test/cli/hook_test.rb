# frozen_string_literal: true

require 'test_helper'

class HookTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  class BrokenPipe < StringIO
    def write(*) = raise(Errno::EPIPE)
  end

  def setup
    super
    @orq = join_claude('orq.dev', 111)
    @rev = join_claude('rev-1.dev', 222)
  end

  def read_only(dir)
    File.chmod(0o500, dir)
    yield
  ensure
    File.chmod(0o700, dir)
  end

  def stop(env, session_id: env['CLAUDE_CODE_SESSION_ID'])
    keryx('hook', 'stop', env:, input: JSON.generate('session_id' => session_id, 'hook_event_name' => 'Stop'))
  end

  def test_nothing_pending_lets_the_turn_end
    result = stop(@rev)

    assert_equal 0, result.status
    assert_empty result.out
  end

  def test_unread_mail_blocks_the_turn_once
    keryx('send', 'rev-1.dev', 'hello', env: @orq)
    id = last_id(@rev)
    decision = JSON.parse(stop(@rev).out)

    assert_equal 'block', decision['decision']
    assert_equal "keryx: rev-1.dev has 1 unread message (#{id}). Open each with 'keryx read ID' before ending " \
                 'the turn.', decision['reason']
    assert_empty stop(@rev).out
  end

  def test_an_unread_request_is_to_be_answered
    keryx('ask', 'rev-1.dev', 'Review PR #448', env: @orq)
    id = last_id(@rev)

    assert_equal "keryx: rev-1.dev has 1 unread message (#{id}). Open each with 'keryx read ID' and answer every " \
                 "request with 'keryx reply ID TEXT' before ending the turn, or with 'keryx send --re ID TEXT' if " \
                 'you took it and its work goes on; if a request cannot be done, reply saying why.',
                 JSON.parse(stop(@rev).out)['reason']
  end

  def test_a_reminder_cut_off_before_it_reaches_the_harness_is_given_again
    keryx('send', 'rev-1.dev', 'hello', env: @orq)
    payload = JSON.generate('session_id' => 'session-222', 'hook_event_name' => 'Stop')
    cut = keryx('hook', 'stop', env: @rev, input: payload, out: BrokenPipe.new)
    again = stop(@rev).out

    assert_equal 0, cut.status
    refute_empty again
    assert_equal 'block', JSON.parse(again)['decision']
  end

  def test_a_reminder_that_cannot_be_recorded_lets_the_turn_end
    skip 'root writes to a read-only directory' if Process.uid.zero?

    keryx('send', 'rev-1.dev', 'hello', env: @orq)
    runs = read_only(tmp('state', 'addresses', 'rev-1.dev', 'receipts')) { Array.new(3) { stop(@rev) } }

    assert_equal([[0, '']] * 3, runs.map { [it.status, it.out] })
    assert(runs.all? { it.err.start_with?('keryx hook stop: Permission denied') })
  end

  def test_a_reminder_whose_mark_cannot_be_written_never_goes_out
    keryx('send', 'rev-1.dev', 'hello', env: @orq)
    full = store
    full.define_singleton_method(:prepare_mark) { |*| raise Errno::ENOSPC, 'receipts' }
    hook = Keryx::StopHook.new(store: full, herdr:, caller: Keryx::Caller.from_env(@rev, cwd: '/work', herdr:),
                               meter: nil)
    given = []

    assert_raises(Errno::ENOSPC) { hook.decide('session_id' => 'session-222') { given << it } }
    assert_empty given
  end

  def test_a_request_read_but_not_answered_blocks_once
    keryx('ask', 'rev-1.dev', 'Review PR #448', env: @orq)
    id = last_id(@rev)
    keryx('read', env: @rev)
    decision = JSON.parse(stop(@rev).out)

    assert_match(/1 request read but not answered \(#{id} from orq.dev@athena\)\. .* answer every request with/,
                 decision['reason'])
    assert_empty stop(@rev).out
  end

  def test_the_session_id_from_the_payload_identifies_the_session
    keryx('send', 'rev-1.dev', 'hello', env: @orq)
    env = { 'CLAUDE_CODE_SESSION_ID' => '' }

    assert_equal 'block', JSON.parse(stop(env, session_id: 'session-222').out)['decision']
  end

  def test_cursor_gets_the_reminder_as_a_follow_up_message
    keryx('join', 'audit.dev', env: { 'CURSOR_CONVERSATION_ID' => 'conversation-1' })
    keryx('send', 'audit.dev', 'hello', env: @orq)
    id = last_id({ 'CURSOR_CONVERSATION_ID' => 'conversation-1' })
    payload = JSON.generate('conversation_id' => 'conversation-1', 'cursor_version' => '2026.10.19',
                            'hook_event_name' => 'stop', 'status' => 'completed', 'loop_count' => 0)
    first = keryx('hook', 'stop', input: payload).out

    assert_match(/\Akeryx: audit.dev has 1 unread message \(#{id}\)\./, JSON.parse(first)['followup_message'])
    assert_equal "{}\n", keryx('hook', 'stop', input: payload).out
  end

  def test_a_cursor_hook_inside_claude_code_is_not_taken_for_it
    keryx('send', 'orq.dev', 'hello', env: @rev)
    payload = JSON.generate('conversation_id' => 'conversation-1', 'cursor_version' => '2026.10.19')

    assert_equal "{}\n", keryx('hook', 'stop', env: @orq, input: payload).out
    assert_equal 'block', JSON.parse(stop(@orq).out)['decision']
  end

  def test_codex_gets_the_reminder_as_a_block_decision
    keryx('join', 'impl.dev', env: { 'CODEX_THREAD_ID' => 'thread-1' })
    keryx('send', 'impl.dev', 'hello', env: @orq)
    payload = JSON.generate('session_id' => 'thread-1', 'turn_id' => 'turn-1', 'hook_event_name' => 'Stop')
    decision = JSON.parse(keryx('hook', 'stop', input: payload).out)

    assert_equal 'block', decision['decision']
    assert_match(/\Akeryx: impl.dev has 1 unread message/, decision['reason'])
  end

  def test_a_session_with_no_address_is_left_alone
    alive << 333

    assert_empty stop(claude(333)).out
  end

  def test_a_bad_payload_never_fails_the_session
    result = keryx('hook', 'stop', env: @rev, input: '{not json')

    assert_equal 0, result.status
    assert_match(/keryx hook stop: /, result.err)
  end

  def test_damaged_input_cannot_put_control_characters_on_the_screen
    keryx('join', 'broken.dev', env: claude(333))
    File.write(tmp('state', 'addresses', 'broken.dev', 'occupant.json'), "{\"joined_at\": bad\e[2J}\n")
    damaged = [stop(@rev), keryx('hook', 'stop', env: @rev, input: "{\"session_id\": bad\e[2J}")]

    assert_match(/\Awarning: .*occupant\.json is not valid JSON .*bad\^\[\[2J/, damaged.first.err)
    assert_match(/\Akeryx hook stop: .*bad\^\[\[2J/, damaged.last.err)
    damaged.each { assert_equal [0, '', false], [it.status, it.out, it.err.include?("\e")] }
  end

  def test_a_payload_that_is_not_an_object_never_fails_the_session
    ['[]', 'null', 'true', '1', '"stop"'].each do |payload|
      result = keryx('hook', 'stop', env: @rev, input: payload)

      assert_equal [0, ''], [result.status, result.out], payload
      assert_equal "keryx hook stop: the payload is not a JSON object\n", result.err
    end
  end

  def test_fields_of_unexpected_types_never_fail_the_session
    keryx('send', 'rev-1.dev', 'hello', env: @orq)
    payload = JSON.generate('session_id' => 42, 'turn_id' => [], 'conversation_id' => {})

    assert_equal [0, '', ''], keryx('hook', 'stop', input: payload).to_h.values_at(:status, :out, :err)
  end

  def test_an_unknown_event_is_a_usage_error
    assert_equal 2, keryx('hook', 'start', env: @rev).status
  end

  def transcript_at(*parts)
    path = tmp('home', '.claude', 'projects', *parts)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, '')
    path
  end

  def stop_with_transcript(path, env: @rev)
    keryx('hook', 'stop', env:, input: JSON.generate('session_id' => env['CLAUDE_CODE_SESSION_ID'],
                                                     'transcript_path' => path, 'hook_event_name' => 'Stop'))
  end

  def recorded(name) = store.occupant(name).transcript

  def test_the_hook_records_the_transcript_claude_code_names_and_keeps_it_through_a_refresh
    path = transcript_at('-work', 'session-222.jsonl')

    assert_equal [0, ''], stop_with_transcript(path).to_h.values_at(:status, :out)
    assert_equal path, recorded('rev-1.dev')
    keryx('whoami', env: @rev.merge('CLAUDE_CODE_MESSAGING_SOCKET' => '/tmp/cc-222-new.sock'))

    occupant = store.occupant('rev-1.dev')

    assert_equal ['/tmp/cc-222-new.sock', path], [occupant.claude_socket, occupant.transcript]
  end

  def test_the_hook_records_no_transcript_outside_where_claude_code_keeps_that_session
    outside = tmp('outside', 'session-222.jsonl')
    FileUtils.mkdir_p(File.dirname(outside))
    File.write(outside, '')
    linked = tmp('home', '.claude', 'projects', '-linked', 'session-222.jsonl')
    FileUtils.mkdir_p(File.dirname(linked))
    File.symlink(outside, linked)
    [outside, linked, transcript_at('-work', 'session-111.jsonl'), 'session-222.jsonl', 42].each do |path|
      assert_equal 0, stop_with_transcript(path).status
      assert_nil recorded('rev-1.dev'), path
    end
  end

  def test_the_hook_records_no_transcript_of_another_session_run_by_the_same_process
    path = transcript_at('-work', 'session-333.jsonl')
    result = stop_with_transcript(path, env: @rev.merge('CLAUDE_CODE_SESSION_ID' => 'session-333'))

    assert_equal 0, result.status
    assert_nil recorded('rev-1.dev')
  end

  def test_the_hook_leaves_the_transcript_to_a_later_turn_while_another_command_holds_the_lock
    keryx('send', 'rev-1.dev', 'hello', env: @orq)
    path = transcript_at('-work', 'session-222.jsonl')
    result = store.with_occupants_lock { stop_with_transcript(path) }

    assert_equal ['block', ''], [JSON.parse(result.out)['decision'], result.err]
    assert_nil recorded('rev-1.dev')
    stop_with_transcript(path)

    assert_equal path, recorded('rev-1.dev')
  end

  def test_a_transcript_path_the_hook_cannot_use_never_changes_its_decision
    keryx('send', 'rev-1.dev', 'hello', env: @orq)
    elsewhere = tmp('other', 'projects', '-work', 'session-222.jsonl')
    FileUtils.mkdir_p(File.dirname(elsewhere))
    File.write(elsewhere, '')
    runs = ["#{transcript_at('-work', 'session-222.jsonl')}\0", elsewhere].map { stop_with_transcript(it) }

    assert_equal([[0, ''], [0, '']], runs.map { [it.status, it.err] })
    assert_equal 'block', JSON.parse(runs.first.out)['decision']
    assert_nil recorded('rev-1.dev')
  end
end
