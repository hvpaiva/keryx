# frozen_string_literal: true

require 'test_helper'

class OccupantsLockTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers
  include ProcessRaces

  def teardown
    @threads&.each { it.join(SECONDS) }
    super
  end

  def test_wait_keeps_its_timeout_while_another_command_holds_the_lock
    author = join_claude('author', 111)
    keryx('ask', 'person', 'Stays open', env: author)
    id = store.unread('person').first.id
    holding_the_lock do
      began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      waiting = start('wait', 'wait', id, '--timeout', '1s', env: author.merge('CLAUDE_PID' => '222'), pause: 'none')

      assert_equal({ 'wait' => 3 }, finish([waiting]))
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - began, :<, 3
    end
  end

  def test_spawn_keeps_its_timeout_while_another_command_holds_the_lock
    orq = join_claude('orq', 111)
    session_runs
    holding_the_lock do
      result = in_time do
        spawn('rev-1', '--harness', 'claude', '--timeout', '3s', 'Review it', env: orq.merge('CLAUDE_PID' => '222'))
      end

      assert_equal [3, 3.0], [result.status, clock.now - NOW]
      assert_equal 111, store.occupant('orq').pid
    end
  end

  def test_a_join_gives_up_when_another_command_keeps_the_lock
    holding_the_lock do
      result = in_time { keryx('join', 'beta', env: { 'CODEX_THREAD_ID' => 'late' }) }

      assert_equal 1, result.status
      assert_equal "error: #{tmp('state', 'occupants.lock')} stayed locked by another keryx command for 15s; try " \
                   "again, or end that command if it is stuck\n", result.err
      assert_in_delta 15, clock.now - NOW, 0.1
      assert_nil store.occupant('beta')
    end
  end

  private

  def holding_the_lock
    FileUtils.mkdir_p(tmp('state'))
    File.open(tmp('state', 'occupants.lock'), File::RDWR | File::CREAT) do |file|
      file.flock(File::LOCK_EX)
      yield
    end
  end

  # A command that waited for the lock without a deadline would never return while the test holds it.
  def in_time(&)
    thread = Thread.new(&)
    (@threads ||= []) << thread
    flunk('the command still waits for the occupants lock') unless thread.join(SECONDS)
    thread.value
  end
end
