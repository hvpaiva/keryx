# frozen_string_literal: true

require 'rbconfig'

# Runs real keryx commands that stop at chosen points, to put them in a given order against each other.
module ProcessRaces
  EXE = File.expand_path('../../exe/keryx', __dir__)
  LIB = File.expand_path('../../lib', __dir__)
  SECONDS = 5
  # Loaded into each command: it stops before writing an occupant, or after the first occupant read of
  # App#refresh, and marks when it asks for the lock.
  PAUSE = <<~'RUBY'
    require 'keryx'

    module Pause
      def self.mark(stage) = File.write("#{ENV.fetch('PAUSE_AT')}.#{stage}", '')

      def self.hold(stage)
        mark(stage)
        sleep(0.01) until File.exist?(ENV.fetch('PAUSE_RELEASE'))
      end

      def self.first_refresh?(from)
        return false if @refreshed || ENV['PAUSE_ON'] != 'refresh' || from.base_label != 'refresh'

        @refreshed = true
      end

      def with_occupants_lock(...)
        Pause.mark('waiting')
        super
      end

      def bind(...)
        Pause.hold('ready') if ENV['PAUSE_ON'] == 'bind'
        super
      end

      def occupant(...)
        from = caller_locations(1, 1).first
        super.tap { Pause.hold('ready') if Pause.first_refresh?(from) }
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

  def start(label, *argv, env:, pause: 'bind')
    at = tmp("pause-#{label}")
    pid = Process.spawn(command_env(at, pause).merge(env), RbConfig.ruby, '-I', LIB, '-r', tmp('pause.rb'), EXE,
                        *argv, unsetenv_others: true, out: "#{at}.out", err: "#{at}.err")
    @started << pid
    Command.new(label:, pid:)
  end

  def command_env(at, pause)
    { 'PATH' => ENV.fetch('PATH', ''), 'HOME' => tmp, 'KERYX_HOME' => tmp('state'), 'KERYX_HOST' => 'athena',
      'USER' => 'person', 'PAUSE_AT' => at, 'PAUSE_ON' => pause, 'PAUSE_RELEASE' => tmp('release') }
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
