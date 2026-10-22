# frozen_string_literal: true

require 'test_helper'

class HarnessTest < Minitest::Test
  ENV_FOR_SESSION = { 'KERYX_HOME' => '/state/keryx', 'KERYX_HOST' => 'athena' }.freeze

  def arguments(kind, **) = Keryx::Harness.arguments(kind, name: 'rev-1', env: ENV_FOR_SESSION, **)

  def test_claude_is_named_and_gets_the_keryx_settings_for_that_session
    settings = JSON.parse(arguments('claude').last)

    assert_equal ['-n', 'rev-1', '--remote-control', 'rev-1', '--settings'], arguments('claude')[0...-1]
    assert_equal 'accept', settings['crossSessionInbound']
    assert_equal 'keryx hook stop', settings.dig('hooks', 'Stop', 0, 'hooks', 0, 'command')
  end

  def test_claude_takes_the_model_and_the_effort_as_flags
    assert_equal ['-n', 'rev-1', '--remote-control', 'rev-1', '--model', 'haiku', '--effort', 'low', '--settings'],
                 arguments('claude', model: 'haiku', effort: 'low')[0...-1]
  end

  def test_codex_gets_the_model_the_effort_and_the_store_through_its_config
    assert_equal ['-c', 'model="gpt-5.4"', '-c', 'model_reasoning_effort="low"',
                  '-c', 'shell_environment_policy.set.KERYX_HOME="/state/keryx"',
                  '-c', 'shell_environment_policy.set.KERYX_HOST="athena"'],
                 arguments('codex', model: 'gpt-5.4', effort: 'low')
  end

  def test_codex_values_are_quoted_as_toml_strings
    quoted = Keryx::Harness.arguments('codex', name: 'x', env: { 'KERYX_HOME' => '/a "b"\\c' })

    assert_equal ['-c', 'shell_environment_policy.set.KERYX_HOME="/a \"b\"\\\\c"'], quoted
  end

  def test_cursor_takes_a_model_and_refuses_an_effort
    assert_equal ['--model', 'sonnet-4'], arguments('cursor', model: 'sonnet-4')
    assert_empty arguments('cursor')
    error = assert_raises(Keryx::UsageError) { arguments('cursor', effort: 'high') }

    assert_match(/cursor takes no --effort/, error.message)
  end
end
