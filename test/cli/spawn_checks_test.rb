# frozen_string_literal: true

require 'test_helper'

class SpawnChecksTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers

  REFUSED = {
    %w[rev-1 hello] => [2, /missing --harness/], %w[Rev --harness claude] => [1, /invalid name/],
    ['rev-1', '--harness', 'claude', '--role', "x\e"] => [2, /invalid role/],
    %w[rev-1 --harness cursor --effort high] => [2, /cursor takes no --effort/],
    %w[rev-1 --harness claude --within 1h] => [2, /--within needs a request/],
    ['rev-1', '--harness', 'claude', '--tab', 'a/b'] => [2, /invalid tab label/],
    ['rev-1', '--harness', 'claude', '--model', 'two words'] => [2, /invalid --model/],
    %w[rev-1 --harness claude --cwd /no/such/dir] => [1, %r{no directory /no/such/dir}],
    ['rev-1', '--harness', 'claude', '--', "--x\ry"] => [2, /control character/],
    %w[rev-1 --harness bash] => [2, /invalid argument: --harness bash/],
    %w[rev-1 --harness claude --split left] => [2, /invalid argument: --split left/],
    %w[rev-1 --harness claude --timeout soon] => [2, /invalid duration/],
    ['rev-1', '--harness', 'claude', ' '] => [2, /the message is empty/]
  }.freeze

  def test_spawn_runs_only_in_a_herdr_pane
    result = keryx('spawn', 'rev-1', '--harness', 'claude', 'Review it')

    assert_equal 1, result.status
    assert_match(/runs only in a herdr pane/, result.err)
    refute store.address?('rev-1')
  end

  def test_spawn_checks_everything_before_it_creates_anything
    REFUSED.each do |argv, (status, error)|
      result = spawn(*argv)

      assert_equal [status, true], [result.status, error.match?(result.err)], "#{argv.inspect}: #{result.err}"
    end
    refute store.address?('rev-1')
    assert_empty herdr.splits
  end

  def test_a_harness_argument_that_is_not_utf8_is_refused_before_herdr_is_asked
    runner = FakeRunner.new
    @herdr = Keryx::Herdr.new(runner:)
    result = spawn('rev-1', '--harness', 'claude', '--', "--x\xFF".b)

    assert_equal 2, result.status
    assert_match(/harness argument "--x\\xFF" is not valid UTF-8/, result.err)
    refute store.address?('rev-1')
    assert_empty runner.calls
  end

  def test_an_empty_request_leaves_an_existing_address_as_it_was
    store.create_address('rev-1', role: 'reviewer')
    result = spawn('rev-1', '--harness', 'claude', '--role', 'implementer', ' ')

    assert_equal 2, result.status
    assert_equal 'reviewer', store.address('rev-1').role
  end

  def test_spawn_refuses_an_address_a_live_session_holds
    join_claude('rev-1', 111)
    result = spawn('rev-1', '--harness', 'claude')

    assert_equal 1, result.status
    assert_match(/rev-1@athena is held by another live claude session \(pid 111\); choose another name/, result.err)
    assert_empty herdr.splits
  end

  def test_spawn_refuses_a_name_another_herdr_agent_has
    herdr.put(SOCKET, 'rev-1', agent('w1:p7', 'codex', 'idle'))
    result = spawn('rev-1', '--harness', 'claude')

    assert_equal 1, result.status
    assert_match(/herdr already runs an agent named rev-1, in pane w1:p7/, result.err)
    refute store.address?('rev-1')
  end

  def test_an_agent_that_did_not_join_cannot_hand_out_a_request
    alive << 111
    result = spawn('rev-1', '--harness', 'claude', 'Review it', env: claude(111))

    assert_equal 1, result.status
    assert_match(/this claude session holds no address/, result.err)
    refute store.address?('rev-1')
  end
end
