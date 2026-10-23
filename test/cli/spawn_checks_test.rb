# frozen_string_literal: true

require 'test_helper'

class SpawnChecksTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers

  REFUSED = {
    %w[rev-1.dev hello] => [2, /missing --harness/], %w[Rev --harness claude] => [1, /invalid name/],
    ['rev-1.dev', '--harness', 'claude', '--role', "x\e"] => [2, /invalid role/],
    %w[rev-1.dev --harness cursor --effort high] => [2, /cursor takes no --effort/],
    %w[rev-1.dev --harness claude --within 1h] => [2, /--within needs a request/],
    ['rev-1.dev', '--harness', 'claude', '--tab', 'a/b'] => [2, /invalid tab label/],
    ['rev-1.dev', '--harness', 'claude', '--model', 'two words'] => [2, /invalid --model/],
    %w[rev-1.dev --harness claude --cwd /no/such/dir] => [1, %r{no directory /no/such/dir}],
    ['rev-1.dev', '--harness', 'claude', '--', "--x\ry"] => [2, /control character/],
    %w[rev-1.dev --harness bash] => [2, /invalid argument: --harness bash/],
    %w[rev-1.dev --harness claude --split left] => [2, /invalid argument: --split left/],
    %w[rev-1.dev --harness claude --timeout soon] => [2, /invalid duration/],
    ['rev-1.dev', '--harness', 'claude', ' '] => [2, /the message is empty/]
  }.freeze

  # Runs while spawn looks the herdr name NAME up again just before it frees it, after the lookup of its first check.
  def looking_up(name)
    name = Keryx::Spawner.agent_name(name)
    held = herdr.agent(SOCKET, name)
    lookups = 0
    herdr.put(SOCKET, name, lambda do
      yield if (lookups += 1) == 2
      held
    end)
  end

  # Joins NAME as another process would right before herdr clears the name, after spawn's last address check: there
  # when the occupants lock is free, else once spawn starts the harness. Returns who held NAME at the clear.
  def joins_at_the_clear(name, env)
    [].tap do |holders|
      herdr.on_call = lambda do |call|
        next unless call == :clear_name

        if locked?
          herdr.on_start = ->(*) { joins(name, env) }
        else
          joins(name, env)
        end
        holders << store.occupant(name)&.pid
      end
    end
  end

  def locked?
    store.with_occupants_lock(within: 0) { false }
  rescue Keryx::Store::Busy
    true
  end

  def renamed(from, to, pane)
    herdr.put(SOCKET, Keryx::Spawner.agent_name(from), nil)
    herdr.put(SOCKET, Keryx::Spawner.agent_name(to), agent(pane, 'claude', 'idle'))
  end

  def test_spawn_runs_only_in_a_herdr_pane
    result = keryx('spawn', 'rev-1.dev', '--harness', 'claude', 'Review it')

    assert_equal 1, result.status
    assert_match(/runs only in a herdr pane/, result.err)
    refute store.address?('rev-1.dev')
  end

  def test_spawn_checks_everything_before_it_creates_anything
    REFUSED.each do |argv, (status, error)|
      result = spawn(*argv)

      assert_equal [status, true], [result.status, error.match?(result.err)], "#{argv.inspect}: #{result.err}"
    end
    refute store.address?('rev-1.dev')
    assert_empty herdr.splits
  end

  def test_a_harness_argument_that_is_not_utf8_is_refused_before_herdr_is_asked
    runner = FakeRunner.new
    @herdr = Keryx::Herdr.new(runner:)
    result = spawn('rev-1.dev', '--harness', 'claude', '--', "--x\xFF".b)

    assert_equal 2, result.status
    assert_match(/harness argument "--x\\xFF" is not valid UTF-8/, result.err)
    refute store.address?('rev-1.dev')
    assert_empty runner.calls
  end

  def test_an_empty_request_leaves_an_existing_address_as_it_was
    store.create_address('rev-1.dev', role: 'reviewer')
    result = spawn('rev-1.dev', '--harness', 'claude', '--role', 'implementer', ' ')

    assert_equal 2, result.status
    assert_equal 'reviewer', store.address('rev-1.dev').role
  end

  def test_spawn_refuses_an_address_a_live_session_holds
    join_claude('rev-1.dev', 111)
    result = spawn('rev-1.dev', '--harness', 'claude')

    assert_equal 1, result.status
    assert_match(/rev-1.dev@athena is held by another live claude session \(pid 111\); choose another name/, result.err)
    assert_empty herdr.splits
  end

  def test_spawn_refuses_a_name_a_herdr_agent_in_another_pane_has_and_says_how_to_free_it
    herdr.put(SOCKET, 'rev-1_dev', agent('w1:p7', 'codex', 'idle'))
    result = spawn('rev-1.dev', '--harness', 'claude')

    assert_equal 1, result.status
    assert_equal 'error: herdr already runs an agent named rev-1_dev, in pane w1:p7; choose another name, or free it ' \
                 "with 'herdr agent rename w1:p7 NEWNAME'\n", result.err
    refute store.address?('rev-1.dev')
    assert_equal [[], [], [], []], [herdr.splits, herdr.created_tabs, herdr.cleared, herdr.starts]
  end

  def test_spawn_frees_the_herdr_name_its_own_pane_keeps_after_leaving_just_before_the_start
    caller = left('orq.dev')
    session_joins(pid: 600)
    joins = herdr.on_start
    cleared = nil
    herdr.on_start = lambda do |*started|
      cleared = herdr.cleared.dup
      joins.call(*started)
    end
    result = spawn('orq.dev', '--harness', 'codex', env: caller)

    assert_equal 0, result.status, result.err
    assert_equal [[SOCKET, 'w1:p1']], cleared
    assert_equal([%w[orq_dev w1:p2]], herdr.starts.map { it.values_at(:name, :pane) })
  end

  def test_an_address_joined_again_after_the_check_stops_spawn_before_it_frees_the_name_or_starts
    caller = left('orq.dev')
    meanwhile { joins('orq.dev', caller) }
    result = spawn('orq.dev', '--harness', 'codex', env: caller)

    assert_equal 1, result.status
    assert_equal 'error: orq.dev@athena is held by another live claude session (pid 111, pane w1:p1); it joined ' \
                 'after spawn checked the address, and spawn started no codex session in pane w1:p2; the pane holds ' \
                 "only a shell, which 'herdr pane close w1:p2' closes\n", result.err
    assert_equal [[], []], [herdr.cleared, herdr.starts]
  end

  def test_an_address_joined_again_while_spawn_looks_up_the_herdr_name_stops_it_before_it_frees_the_name
    caller = left('orq.dev')
    looking_up('orq.dev') { joins('orq.dev', caller) }
    result = spawn('orq.dev', '--harness', 'codex', env: caller)

    assert_equal 1, result.status
    assert_equal 'error: orq.dev@athena is held by another live claude session (pid 111, pane w1:p1); it joined ' \
                 'after spawn checked the address, and spawn started no codex session in pane w1:p2; the pane holds ' \
                 "only a shell, which 'herdr pane close w1:p2' closes\n", result.err
    assert_equal [[], [], 111], [herdr.cleared, herdr.starts, store.occupant('orq.dev').pid]
  end

  def test_a_join_after_the_last_address_check_lands_only_after_spawn_cleared_the_name_of_the_vacant_address
    caller = left('orq.dev')
    holders = joins_at_the_clear('orq.dev', caller)
    result = spawn('orq.dev', '--harness', 'codex', env: caller)

    assert_equal 1, result.status
    assert_equal 'error: orq.dev@athena was joined by another claude session, not the one spawn started in pane ' \
                 "w1:p2; 'keryx who' shows it\n", result.err
    assert_equal [[nil], [[SOCKET, 'w1:p1']], 111], [holders, herdr.cleared, store.occupant('orq.dev').pid]
  end

  def test_a_herdr_name_lookup_that_ends_at_the_timeout_frees_no_name_and_starts_no_harness
    caller = left('orq.dev')
    looking_up('orq.dev') { clock.advance(3) }
    result = spawn('orq.dev', '--harness', 'codex', '--timeout', '3s', env: caller)

    assert_equal 3, result.status
    assert_equal 'error: the timeout passed after spawn opened pane w1:p2, and it started no codex session there; ' \
                 "the pane holds only a shell, which 'herdr pane close w1:p2' closes\n", result.err
    assert_equal [[], []], [herdr.cleared, herdr.starts]
  end

  def test_an_address_a_session_joined_while_the_pane_opened_starts_no_harness
    meanwhile { join_claude('rev-1.dev', 111) }
    result = spawn('rev-1.dev', '--harness', 'claude')

    assert_equal 1, result.status
    assert_match(/\Aerror: rev-1.dev@athena is held by another live claude session \(pid 111\); it joined after spawn /,
                 result.err)
    assert_equal [1, [], []], [herdr.splits.size, herdr.cleared, herdr.starts]
  end

  def test_a_herdr_name_the_own_pane_traded_for_another_after_the_check_is_not_cleared
    caller = left('orq.dev')
    session_joins(pid: 600)
    meanwhile do
      renamed('orq.dev', 'keeper.dev', 'w1:p1')
      joins('keeper.dev', caller)
    end
    result = spawn('orq.dev', '--harness', 'codex', env: caller)

    assert_equal 0, result.status, result.err
    assert_empty herdr.cleared
    assert_equal([%w[orq_dev w1:p2]], herdr.starts.map { it.values_at(:name, :pane) })
    assert_equal [111, 'w1:p2'], [store.occupant('keeper.dev').pid, store.occupant('orq.dev').herdr_pane]
  end

  def test_a_herdr_name_and_address_another_pane_took_after_the_check_stop_spawn_before_it_clears_or_starts
    caller = left('orq.dev')
    meanwhile do
      renamed('orq.dev', 'keeper.dev', 'w1:p1')
      joins('keeper.dev', caller)
      herdr.put(SOCKET, 'orq_dev', agent('w1:p7', 'claude', 'idle'))
      alive << 222
      joins('orq.dev', claude(222).merge(in_pane(SOCKET, 'w1:p7')))
    end
    result = spawn('orq.dev', '--harness', 'codex', env: caller)

    assert_equal 1, result.status
    assert_equal 'error: orq.dev@athena is held by another live claude session (pid 222, pane w1:p7); it joined ' \
                 'after spawn checked the address, and spawn started no codex session in pane w1:p2; the pane holds ' \
                 "only a shell, which 'herdr pane close w1:p2' closes\n", result.err
    assert_equal [[], [], 111], [herdr.cleared, herdr.starts, store.occupant('keeper.dev').pid]
  end

  def test_a_herdr_name_spawn_cannot_free_is_an_error_with_herdr_reason
    herdr.put(SOCKET, 'orq_dev', agent('w1:p1', 'claude', 'idle'))
    herdr.clear_error = 'herdr agent rename failed: agent orq is not in pane w1:p1'
    result = spawn('orq.dev', '--harness', 'claude')

    assert_equal 1, result.status
    assert_equal 'error: spawn could not free the herdr name orq_dev in pane w1:p1: herdr agent rename failed: ' \
                 "agent orq is not in pane w1:p1\n", result.err
    assert_empty herdr.starts
  end

  def test_an_agent_that_did_not_join_cannot_hand_out_a_request
    alive << 111
    result = spawn('rev-1.dev', '--harness', 'claude', 'Review it', env: claude(111))

    assert_equal 1, result.status
    assert_match(/this claude session holds no address/, result.err)
    refute store.address?('rev-1.dev')
  end
end
