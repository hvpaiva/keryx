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
    @orq = join_claude('orq', 111)
    @rev = join_claude('rev-1', 222)
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
    keryx('send', 'rev-1', 'hello', env: @orq)
    id = last_id(@rev)
    decision = JSON.parse(stop(@rev).out)

    assert_equal 'block', decision['decision']
    assert_match(/\Akeryx: rev-1 has 1 unread message \(#{id}\)\. Open each with 'keryx read ID'/, decision['reason'])
    assert_empty stop(@rev).out
  end

  def test_a_reminder_cut_off_before_it_reaches_the_harness_is_given_again
    keryx('send', 'rev-1', 'hello', env: @orq)
    payload = JSON.generate('session_id' => 'session-222', 'hook_event_name' => 'Stop')
    cut = keryx('hook', 'stop', env: @rev, input: payload, out: BrokenPipe.new)
    again = stop(@rev).out

    assert_equal 0, cut.status
    refute_empty again
    assert_equal 'block', JSON.parse(again)['decision']
  end

  def test_a_reminder_that_cannot_be_recorded_lets_the_turn_end
    skip 'root writes to a read-only directory' if Process.uid.zero?

    keryx('send', 'rev-1', 'hello', env: @orq)
    runs = read_only(tmp('state', 'addresses', 'rev-1', 'receipts')) { Array.new(3) { stop(@rev) } }

    assert_equal([[0, '']] * 3, runs.map { [it.status, it.out] })
    assert(runs.all? { it.err.start_with?('keryx hook stop: Permission denied') })
  end

  def test_a_reminder_whose_mark_cannot_be_written_never_goes_out
    keryx('send', 'rev-1', 'hello', env: @orq)
    full = store
    full.define_singleton_method(:prepare_mark) { |*| raise Errno::ENOSPC, 'receipts' }
    hook = Keryx::StopHook.new(store: full, herdr:, caller: Keryx::Caller.from_env(@rev, cwd: '/work', herdr:))
    given = []

    assert_raises(Errno::ENOSPC) { hook.decide('session_id' => 'session-222') { given << it } }
    assert_empty given
  end

  def test_a_request_read_but_not_answered_blocks_once
    keryx('ask', 'rev-1', 'Review PR #448', env: @orq)
    id = last_id(@rev)
    keryx('read', env: @rev)
    decision = JSON.parse(stop(@rev).out)

    assert_match(/1 request read but not answered \(#{id} from orq@athena\)/, decision['reason'])
    assert_empty stop(@rev).out
  end

  def test_the_session_id_from_the_payload_identifies_the_session
    keryx('send', 'rev-1', 'hello', env: @orq)
    env = { 'CLAUDE_CODE_SESSION_ID' => '' }

    assert_equal 'block', JSON.parse(stop(env, session_id: 'session-222').out)['decision']
  end

  def test_cursor_gets_the_reminder_as_a_follow_up_message
    keryx('join', 'audit', env: { 'CURSOR_CONVERSATION_ID' => 'conversation-1' })
    keryx('send', 'audit', 'hello', env: @orq)
    id = last_id({ 'CURSOR_CONVERSATION_ID' => 'conversation-1' })
    payload = JSON.generate('conversation_id' => 'conversation-1', 'cursor_version' => '2026.10.19',
                            'hook_event_name' => 'stop', 'status' => 'completed', 'loop_count' => 0)
    first = keryx('hook', 'stop', input: payload).out

    assert_match(/\Akeryx: audit has 1 unread message \(#{id}\)\./, JSON.parse(first)['followup_message'])
    assert_equal "{}\n", keryx('hook', 'stop', input: payload).out
  end

  def test_a_cursor_hook_inside_claude_code_is_not_taken_for_it
    keryx('send', 'orq', 'hello', env: @rev)
    payload = JSON.generate('conversation_id' => 'conversation-1', 'cursor_version' => '2026.10.19')

    assert_equal "{}\n", keryx('hook', 'stop', env: @orq, input: payload).out
    assert_equal 'block', JSON.parse(stop(@orq).out)['decision']
  end

  def test_codex_gets_the_reminder_as_a_block_decision
    keryx('join', 'impl', env: { 'CODEX_THREAD_ID' => 'thread-1' })
    keryx('send', 'impl', 'hello', env: @orq)
    payload = JSON.generate('session_id' => 'thread-1', 'turn_id' => 'turn-1', 'hook_event_name' => 'Stop')
    decision = JSON.parse(keryx('hook', 'stop', input: payload).out)

    assert_equal 'block', decision['decision']
    assert_match(/\Akeryx: impl has 1 unread message/, decision['reason'])
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

  def test_a_payload_that_is_not_an_object_never_fails_the_session
    ['[]', 'null', 'true', '1', '"stop"'].each do |payload|
      result = keryx('hook', 'stop', env: @rev, input: payload)

      assert_equal [0, ''], [result.status, result.out], payload
      assert_equal "keryx hook stop: the payload is not a JSON object\n", result.err
    end
  end

  def test_fields_of_unexpected_types_never_fail_the_session
    keryx('send', 'rev-1', 'hello', env: @orq)
    payload = JSON.generate('session_id' => 42, 'turn_id' => [], 'conversation_id' => {})

    assert_equal [0, '', ''], keryx('hook', 'stop', input: payload).to_h.values_at(:status, :out, :err)
  end

  def test_an_unknown_event_is_a_usage_error
    assert_equal 2, keryx('hook', 'start', env: @rev).status
  end

  def test_the_skill_is_a_skill_file
    output = keryx('skill').out

    assert_match(/\A---\nname: keryx\ndescription: .+\n---\n/, output)
    assert_includes output, 'keryx reply ID TEXT'
  end

  def test_the_skill_says_where_the_host_of_an_address_comes_from
    host = keryx('skill').out.lines.drop_while { !it.include?('NAME@HOST') }.slice_before(/\A- /).first.join

    %w[KERYX_HOST ~/.config/keryx/config hostname ssh].each { assert_includes host, it }
  end
end
