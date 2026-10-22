# frozen_string_literal: true

require 'test_helper'

class HelpTest < Minitest::Test
  include TempDir
  include CLIHelpers

  def test_bare_keryx_prints_the_commands_by_section
    result = keryx

    assert_equal 0, result.status
    assert_match(/^Session Commands:\n  join /, result.out)
    assert_match(/^Mail Commands:\n  send /, result.out)
    refute_includes result.out, '__complete'
  end

  def test_bare_keryx_lists_the_environment_and_the_exit_statuses
    result = keryx

    assert_match(/^Environment:\n  KERYX_HOME +Where the mailboxes live/, result.out)
    assert_match(/^Exit Status:\n  0 +Success\n/, result.out)
    assert_match(/^  3 +keryx wait gave up before the reply arrived$/, result.out)
  end

  def test_command_help_lists_its_own_options_apart_from_the_global_ones
    result = keryx('ask', '--help')

    assert_equal 0, result.status
    assert_match(/^Usage:\n  keryx ask \[options\] ADDRESS \[TEXT\]$/, result.out)
    assert_match(/^Options:\n  -f, --file PATH .*\n      --within DURATION/, result.out)
    assert_match(/^Global Options:\n      --as NAME/, result.out)
    assert_match(/^Examples:\n  # Ask for a review/, result.out)
  end

  def test_help_command_matches_the_flag
    assert_equal keryx('reply', '--help').out, keryx('help', 'reply').out
    assert_equal keryx.out, keryx('help').out
  end

  def test_help_never_touches_the_mailboxes
    keryx('help', 'status')
    keryx('who', '--help')

    refute_path_exists tmp('state')
  end

  def test_prose_wraps_at_the_terminal_width
    lines = keryx('ask', '--help', env: { 'COLUMNS' => '60' }).out.lines

    assert_operator lines.reject { it.start_with?('  ') }.map { it.chomp.size }.max, :<=, 60
  end

  def test_an_unknown_command_suggests_the_closest
    result = keryx('inbx')

    assert_equal 2, result.status
    assert_match(/error: unknown command "inbx" for "keryx"\n\nDid you mean this\?\n\tinbox/, result.err)
    assert_match(/Run 'keryx --help' for usage/, result.err)
  end

  def test_usage_errors_exit_two_and_point_at_the_command_help
    [%w[send], %w[inbox --bogus], %w[read a b], %w[inbox -o yaml]].each do |argv|
      result = keryx(*argv)

      assert_equal 2, result.status, argv.inspect
      assert_match(/Run 'keryx #{argv.first} --help' for usage/, result.err)
    end
  end

  def test_version
    assert_equal "keryx #{Keryx::VERSION} (ruby #{RUBY_VERSION})\n", keryx('version').out
    assert_equal keryx('version').out, keryx('-V').out
  end

  def test_color_follows_the_flag_and_no_color
    assert_includes keryx('--color', 'help').out, "\e[1mUsage:\e[0m"
    refute_includes keryx('--color=never', 'help').out, "\e["
    refute_includes keryx('help', env: { 'NO_COLOR' => '1' }).out, "\e["
    assert_includes keryx('help', env: { 'FORCE_COLOR' => '1' }).out, "\e["
  end

  def test_an_invalid_keryx_color_is_a_usage_error
    assert_equal 2, keryx('help', env: { 'KERYX_COLOR' => 'rainbow' }).status
  end
end
