# frozen_string_literal: true

require 'test_helper'

class SpawnCommandLineTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers

  def test_a_prompt_of_two_kibibytes_reaches_the_harness_whole
    session_joins
    prompt = 'x' * 2048
    result = spawn('rev-1.dev', '--harness', 'claude', '--prompt', prompt)

    assert_equal 0, result.status, result.err
    assert_includes herdr.starts.last[:arguments].last, prompt
  end

  def test_a_longer_prompt_is_refused_before_anything_is_created
    runner = unreached_herdr
    result = spawn('rev-1.dev', '--harness', 'claude', '--prompt', 'x' * 2049, 'Review it')

    assert_equal 2, result.status
    assert_match(/--prompt is 2049 bytes and the limit is 2048: the first prompt is part of the harness's command/,
                 result.err)
    assert_match(/which any local process can read\. Give longer instructions as the request, with TEXT or --file, /,
                 result.err)
    refute store.address?('rev-1.dev')
    assert_empty runner.calls
  end

  def test_the_prompt_limit_counts_bytes
    runner = unreached_herdr
    result = spawn('rev-1.dev', '--harness', 'claude', '--prompt', "\u00E9" * 1025)

    assert_equal 2, result.status
    assert_match(/--prompt is 2050 bytes/, result.err)
    assert_empty runner.calls
  end

  # A Claude Code caller names its harness itself, so herdr is not asked who runs the caller's pane.
  def test_a_line_its_quotes_take_past_the_limit_is_refused_before_herdr_is_asked
    runner = unreached_herdr
    result = spawn('rev-1.dev', '--harness', 'claude', 'Review it', '--', "don't " * 600, env: claude(111))

    assert_equal 2, result.status
    assert_match(/the command herdr would type into the new pane's shell is \d+ bytes, and a shell line holds at /,
                 result.err)
    assert_match(/at most 4000 here before the terminal cuts it; give long text as the request, with TEXT or --file, /,
                 result.err)
    assert_match(/long values such as PATH through the environment of the pane \(the shell's rc or the herdr /,
                 result.err)
    refute store.address?('rev-1.dev')
    assert_empty runner.calls
  end

  def test_a_command_line_that_fills_a_shell_line_starts
    session_joins
    fill = padding(4000)

    assert_equal 2, spawn('rev-1.dev', '--harness', 'claude', '--', "#{fill}x").status
    assert_equal 0, spawn('rev-1.dev', '--harness', 'claude', '--', fill).status
    assert_equal fill, herdr.starts.last[:arguments][-3]
  end

  def test_macos_holds_a_shorter_line
    @host_os = 'darwin24'
    session_joins
    fill = padding(1000)

    assert_match(/a shell line holds at most 1000 here/,
                 spawn('rev-1.dev', '--harness', 'claude', '--', "#{fill}x").err)
    assert_equal 0, spawn('rev-1.dev', '--harness', 'claude', '--', fill).status
  end

  private

  # The refusal of a padding as long as the limit gives the rest of the line, and so the padding that fills it.
  def padding(limit)
    result = spawn('rev-1.dev', '--harness', 'claude', '--', 'x' * limit)
    bytes = result.err[/is (\d+) bytes/, 1] or flunk("spawn measured no line: #{result.err.inspect}")
    'x' * ((2 * limit) - Integer(bytes))
  end

  # Every herdr command goes through the runner, which records it.
  def unreached_herdr
    FakeRunner.new.tap { @herdr = Keryx::Herdr.new(runner: it) }
  end
end
