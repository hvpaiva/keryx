# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'rbconfig'

class ExecutableTest < Minitest::Test
  include TempDir

  EXE = File.expand_path('../../exe/keryx', __dir__)
  INHERITED = %w[CLAUDECODE CLAUDE_PID CLAUDE_CODE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET HERDR_SOCKET_PATH KERYX_SSH
                 HERDR_PANE_ID CODEX_THREAD_ID CURSOR_CONVERSATION_ID KERYX_AS KERYX_COLOR KERYX_REMOTE_COMMAND NO_COLOR
                 FORCE_COLOR].freeze

  def run_keryx(*argv, env: {}, input: '')
    base = INHERITED.to_h { [it, nil] }.merge('KERYX_HOME' => tmp('state'), 'KERYX_HOST' => 'athena',
                                              'USER' => 'person')
    Open3.capture3(base.merge(env), RbConfig.ruby, EXE, *argv, stdin_data: input)
  end

  def session_env
    { 'CLAUDECODE' => '1', 'CLAUDE_PID' => Process.pid.to_s, 'CLAUDE_CODE_SESSION_ID' => 'session-exe',
      'CLAUDE_CODE_MESSAGING_SOCKET' => tmp('nobody.sock') }
  end

  def test_version_exits_zero
    out, err, status = run_keryx('--version')

    assert_predicate status, :success?
    assert_equal "keryx #{Keryx::VERSION} (ruby #{RUBY_VERSION})\n", out
    assert_empty err
  end

  def test_a_message_goes_from_a_person_to_a_session_and_back
    run_keryx('join', 'rev-1', env: session_env)
    _out, _err, sent = run_keryx('ask', 'rev-1', 'Review it')
    inbox, = run_keryx('inbox', '-o', 'json', env: session_env)
    id = JSON.parse(inbox).first.fetch('id')
    run_keryx('reply', id, '-', env: session_env, input: "Approved\n")
    reply, _err, waited = run_keryx('wait', id, '--timeout', '5s')

    assert_predicate sent, :success?
    assert_predicate waited, :success?
    assert_match(/\n\nApproved\n\z/, reply)
  end

  def test_errors_go_to_stderr_with_a_status
    out, err, status = run_keryx('read', 'ZZZZ')

    assert_equal 1, status.exitstatus
    assert_empty out
    assert_equal "error: no message ZZZZ in the mailbox of person\n", err
  end
end
