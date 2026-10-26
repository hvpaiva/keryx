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
    assert_equal '--settings', added.first
    assert_equal added, typed[typed.index('--settings'), 2]
    assert_equal 'accept', JSON.parse(added.last)['crossSessionInbound']
    assert_nil wiring('claude')['hooks']
    assert_includes keryx('wiring', 'claude').out, "  --settings '#{added.last}'\n"
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

  def test_the_output_holds_nothing_of_the_environment_it_runs_in
    other = { 'KERYX_HOME' => tmp('other-state'), 'HOME' => tmp('other-home'), 'XDG_CONFIG_HOME' => tmp('other'),
              'KERYX_HOST' => 'zeus', **SpawnHelpers::CALLER }

    %w[claude codex cursor].each do |kind|
      [[kind, '-o', 'json'], [kind]].each do |argv|
        here = keryx('wiring', *argv)

        assert_equal here, keryx('wiring', *argv, env: other)
        refute_includes here.out, tmp
      end
    end

    refute_path_exists tmp('state')
  end

  def test_the_harness_completes
    assert_equal %w[claude codex cursor], keryx('__complete', 'wiring', '').out.lines(chomp: true)
  end
end
