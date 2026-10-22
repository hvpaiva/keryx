# frozen_string_literal: true

require 'test_helper'
require 'rbconfig'

class JoinRaceTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  EXE = File.expand_path('../../exe/keryx', __dir__)
  LIB = File.expand_path('../../lib', __dir__)
  SECONDS = 5
  # Loaded into each command: it stops before writing an occupant, and marks when it asks for the lock.
  PAUSE = <<~'RUBY'
    require 'keryx'

    module Pause
      def self.mark(stage) = File.write("#{ENV.fetch('PAUSE_AT')}.#{stage}", '')

      def self.hold(stage)
        mark(stage)
        sleep(0.01) until File.exist?(ENV.fetch('PAUSE_RELEASE'))
      end

      def with_occupants_lock(...)
        Pause.mark('waiting')
        super
      end

      def bind(...)
        Pause.hold('ready')
        super
      end
    end

    Keryx::Store.prepend(Pause)
  RUBY

  Command = Data.define(:label, :pid)

  def setup
    super
    @started = []
    File.write(tmp('pause.rb'), PAUSE)
  end

  def teardown
    @started.each { stop(it) }
    super
  end

  def test_two_joins_of_one_session_at_once_leave_it_one_address
    session = { 'CODEX_THREAD_ID' => 'shared-thread' }
    statuses = finish(release_when_settled(start('alpha', 'join', 'alpha', env: session),
                                           start('beta', 'join', 'beta', env: session)))

    assert_equal [0, 0], statuses.values
    assert_equal 1, held.size, "held: #{held.inspect}"
    assert_equal "#{held.first}@athena", JSON.parse(keryx('whoami', '-o', 'json', env: session).out)['address']
    keryx('leave', env: session)

    assert_match(/holds no address/, keryx('whoami', env: session).err)
  end

  def test_two_sessions_that_join_one_free_address_at_once_get_one_join
    sessions = { 'first' => claude(Process.pid), 'second' => claude(Process.ppid) }
    statuses = finish(release_when_settled(*sessions.map { |label, env| start(label, 'join', 'solo', env:) }))
    winner, loser = statuses.keys.sort_by { statuses[it] }

    assert_equal [0, 1], statuses.values_at(winner, loser)
    assert_match(/solo@athena is held by another live claude session/, File.read(tmp("pause-#{loser}.err")))
    assert_equal sessions.fetch(winner)['CLAUDE_CODE_SESSION_ID'], store.occupant('solo').session_id
  end

  private

  def start(label, *argv, env:)
    at = tmp("pause-#{label}")
    pid = Process.spawn(command_env(at).merge(env), RbConfig.ruby, '-I', LIB, '-r', tmp('pause.rb'), EXE, *argv,
                        unsetenv_others: true, out: "#{at}.out", err: "#{at}.err")
    @started << pid
    Command.new(label:, pid:)
  end

  def command_env(at)
    { 'PATH' => ENV.fetch('PATH', ''), 'HOME' => tmp, 'KERYX_HOME' => tmp('state'), 'KERYX_HOST' => 'athena',
      'USER' => 'person', 'PAUSE_AT' => at, 'PAUSE_RELEASE' => tmp('release') }
  end

  # Both stopped before writing is the race; one stopped and the other waiting for the lock is the serial order.
  def release_when_settled(*commands)
    labels = commands.map(&:label)
    wait_until('both commands to stop or one to wait for the other') do
      ready = labels.select { File.exist?(tmp("pause-#{it}.ready")) }
      waiting = labels.select { File.exist?(tmp("pause-#{it}.waiting")) } - ready
      ready.size == 2 || (ready.size == 1 && waiting.size == 1)
    end
    File.write(tmp('release'), '')
    commands
  end

  def finish(commands)
    commands.to_h do |command|
      status = nil
      wait_until("#{command.label} to exit") { status = Process.wait2(command.pid, Process::WNOHANG)&.last }
      @started.delete(command.pid)
      [command.label, status.exitstatus]
    end
  end

  def wait_until(what)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SECONDS
    until yield
      flunk("timed out waiting for #{what}; #{stderr}") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep(0.01)
    end
  end

  def stop(pid)
    Process.kill('KILL', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def stderr = Dir[tmp('pause-*.err')].map { "#{File.basename(it)}: #{File.read(it).inspect}" }.join('; ')

  def held = store.address_names.select { store.occupant(it) }
end
