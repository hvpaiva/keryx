# frozen_string_literal: true

require 'test_helper'

class HookTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def setup
    super
    @orq = join_claude('orq', 111)
    @rev = join_claude('rev-1', 222)
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

  def test_a_session_with_no_address_is_left_alone
    alive << 333

    assert_empty stop(claude(333)).out
  end

  def test_a_bad_payload_never_fails_the_session
    result = keryx('hook', 'stop', env: @rev, input: '{not json')

    assert_equal 0, result.status
    assert_match(/keryx hook stop: /, result.err)
  end

  def test_an_unknown_event_is_a_usage_error
    assert_equal 2, keryx('hook', 'start', env: @rev).status
  end

  def test_the_skill_is_a_skill_file
    output = keryx('skill').out

    assert_match(/\A---\nname: keryx\ndescription: .+\n---\n/, output)
    assert_includes output, 'keryx reply ID TEXT'
  end
end
