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
    result = spawn('rev-1', '--harness', 'claude', '--prompt', prompt)

    assert_equal 0, result.status, result.err
    assert_includes herdr.starts.last[:arguments].last, prompt
  end

  def test_a_longer_prompt_is_refused_before_anything_is_created
    runner = unreached_herdr
    result = spawn('rev-1', '--harness', 'claude', '--prompt', 'x' * 2049, 'Review it')

    assert_equal 2, result.status
    assert_match(/--prompt is 2049 bytes and the limit is 2048: the first prompt is part of the harness's command/,
                 result.err)
    assert_match(/which any local process can read\. Give longer instructions as the request, with TEXT or --file, /,
                 result.err)
    refute store.address?('rev-1')
    assert_empty runner.calls
  end

  def test_the_prompt_limit_counts_bytes
    runner = unreached_herdr
    result = spawn('rev-1', '--harness', 'claude', '--prompt', "\u00E9" * 1025)

    assert_equal 2, result.status
    assert_match(/--prompt is 2050 bytes/, result.err)
    assert_empty runner.calls
  end

  private

  # Every herdr command goes through the runner, which records it.
  def unreached_herdr
    FakeRunner.new.tap { @herdr = Keryx::Herdr.new(runner: it) }
  end
end
