# frozen_string_literal: true

require 'test_helper'

class WiringTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers

  def wiring(kind, env: {})
    run = keryx('wiring', kind, '-o', 'json', env:)

    assert_equal ['', 0], [run.err, run.status]
    JSON.parse(run.out)
  end

  def test_claude_gets_the_settings_spawn_types_into_its_pane
    session_joins
    result = spawn('rev-1.dev', '--harness', 'claude', 'Review it')
    typed = herdr.starts.last[:arguments]
    added = wiring('claude')['arguments']

    assert_equal 0, result.status, result.err
    assert_equal %w[--disallowedTools AskUserQuestion --settings], added[0...-1]
    assert_equal added, typed[typed.index('--disallowedTools'), added.size]
    assert_equal 'accept', JSON.parse(added.last)['crossSessionInbound']
    assert_nil wiring('claude')['hooks']
    assert_includes keryx('wiring', 'claude').out, "  --disallowedTools AskUserQuestion --settings '#{added.last}'\n"
  end

  def test_codex_and_cursor_take_no_arguments
    assert_equal([[], []], %w[codex cursor].map { wiring(it)['arguments'] })
  end

  def test_the_hooks_entries_are_the_snippets_hook_help_prints
    claude_and_codex, cursor = keryx('hook', '--help').out.scan(/^  (\{.*\})$/).flatten
    codex = wiring('codex')['hooks']

    assert_equal [JSON.parse(claude_and_codex), JSON.parse(cursor)],
                 [codex['entry'], wiring('cursor')['hooks']['entry']]
    assert_equal [%w[~/.codex/hooks.json .codex/hooks.json], %w[~/.cursor/hooks.json .cursor/hooks.json]],
                 [codex['files'], wiring('cursor')['hooks']['files']]
    assert_match(%r{trusted in /hooks}, codex['trust'])
    assert_nil wiring('cursor')['hooks']['trust']
    assert_includes keryx('wiring', 'codex').out, "\n  #{claude_and_codex}\n"
    assert_includes keryx('wiring', 'cursor').out, "\n  #{cursor}\n"
  end

  def test_codex_names_the_variables_spawn_sets_through_its_config
    session_joins
    spawn('impl.dev', '--harness', 'codex')
    typed = herdr.starts.last[:arguments]
    set = typed.each_cons(2).filter_map do |flag, value|
      value[/\Ashell_environment_policy\.set\.(\w+)=/, 1] if flag == '-c'
    end
    environment = wiring('codex')['environment']

    assert_equal set.sort, (environment['store'] + environment['pane']).map { it['name'] }.sort
    assert_equal '-c shell_environment_policy.set.NAME=VALUE', environment['through']
    assert_equal 'environment', wiring('cursor')['environment']['through']
  end

  def test_the_bell_lists_its_channels_in_the_order_it_tries_them
    assert_equal([%w[claude herdr], %w[codex herdr], %w[herdr]], %w[claude codex cursor].map { wiring(it)['bell'] })
  end

  def test_an_unknown_harness_is_a_usage_error_that_lists_the_harnesses
    result = keryx('wiring', 'gemini')

    assert_equal 2, result.status
    assert_match(/unknown harness "gemini"; the harnesses are claude, codex, cursor/, result.err)
    assert_empty result.out
  end

  def test_the_output_holds_nothing_of_the_environment_it_runs_in_apart_from_the_host
    other = { 'KERYX_HOME' => tmp('other-state'), 'HOME' => tmp('other-home'), 'XDG_CONFIG_HOME' => tmp('other'),
              'KERYX_HOST' => 'zeus', **SpawnHelpers::CALLER }

    %w[claude codex cursor].each do |kind|
      assert_equal 'zeus', wiring(kind, env: other)['host']
      assert_equal wiring(kind).except('host'), wiring(kind, env: other).except('host')
      here = keryx('wiring', kind)

      assert_equal here.out.sub('athena.', 'zeus.'), keryx('wiring', kind, env: other).out
      refute_includes here.out, tmp
    end

    refute_path_exists tmp('state')
  end

  def test_the_host_is_the_one_keryx_resolves_from_keryx_host_the_config_file_or_the_machine_name
    write_config("host = cfg-host\n")
    machine = { 'KERYX_HOST' => '', 'XDG_CONFIG_HOME' => tmp('none') }
    resolved = keryx('whoami', '-o', 'json', env: machine).out.then { JSON.parse(it)['address'][/@(.+)\z/, 1] }

    hosts = [{ 'KERYX_HOST' => 'env-host' }, { 'KERYX_HOST' => '' }].map { wiring('claude', env: it)['host'] }

    assert_equal %w[env-host cfg-host], hosts
    assert_equal resolved, wiring('codex', env: machine)['host']
    assert_equal "This keryx resolves its host as cfg-host.\n",
                 keryx('wiring', 'cursor', env: { 'KERYX_HOST' => '' }).out.lines.last
  end

  def test_a_host_keryx_cannot_resolve_fails_as_it_does_for_other_commands
    write_config("host = Bad_Host\n")

    [{ 'KERYX_HOST' => 'Bad_Host' }, { 'KERYX_HOST' => '' }].each do |env|
      result = keryx('wiring', 'claude', '-o', 'json', env:)

      assert_equal [1, '', keryx('whoami', env:).err], [result.status, result.out, result.err]
      assert_match(/"Bad_Host" is not a valid host name/, result.err)
    end
  end

  def test_the_harness_completes
    assert_equal %w[claude codex cursor], keryx('__complete', 'wiring', '').out.lines(chomp: true)
  end
end
