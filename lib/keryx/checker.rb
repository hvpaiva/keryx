# frozen_string_literal: true

require 'etc'

module Keryx
  # Runs one checker on one envelope. The checker gets the path alone as its argv, never a command line, an environment
  # of four variables and / as its folder, in a process group of its own that is killed however the run ends, so a
  # descendant it leaves behind dies with it. Process.spawn, like execvp, runs /bin/sh on a file the kernel cannot
  # execute, so CheckConfig refuses a checker that starts with neither #! nor a binary's magic, and one that starts
  # right but still fails to load meets that fallback. Runner is not used, since it passes keryx's environment through
  # and reads the whole output into memory.
  class Checker
    Outcome = Data.define(:status, :signal, :timed_out, :error, :stderr) do
      def initialize(status: nil, signal: nil, timed_out: false, error: nil, stderr: '') = super
    end

    KEEP = 4096
    CHUNK = 64 * 1024
    KILL_GRACE = 1

    def initialize(home: -> { Checker.home })
      @home = home
    end

    # The home of the user keryx runs as, from the password database rather than HOME, which a session sets freely.
    def self.home
      Etc.getpwuid(Process.uid)&.dir || '/'
    rescue ArgumentError
      '/'
    end

    def call(setup, envelope)
      job = Job.new
      job.start(setup.command, environment)
      job.finish(envelope, setup.timeout)
    rescue SystemCallError => e
      Outcome.new(error: "cannot run #{setup.command}: #{e.message.sub(/ [@-] .*/, '')}")
    ensure
      job&.stop
    end

    private

    def environment = { 'PATH' => '/usr/bin:/bin', 'HOME' => @home.call, 'LANG' => 'C.UTF-8', 'KERYX_CHECK' => '1' }

    class Job
      def initialize
        @ends = []
        @kept = String.new(encoding: Encoding::BINARY)
        @cut = false
      end

      def start(command, env)
        stdin, @input = pipe
        @output, out = pipe
        @errors, err = pipe
        @pid = Process.spawn(env, [command, command], in: stdin, out:, err:, chdir: '/', pgroup: true,
                                                      unsetenv_others: true, close_others: true)
        [stdin, out, err].each(&:close)
        @waiter = Process.detach(@pid)
      end

      # Once the checker is reaped, whatever it gave, what is left in its group is a descendant, killed at once.
      def finish(envelope, timeout)
        deadline = now + timeout
        threads = [writer(envelope), drain(@output), keep(@errors)]
        status = @waiter.join(timeout)&.value or return expire(timeout)

        kill
        threads.each { it.join([deadline - now, 0].max) }
        Outcome.new(status: status.exitstatus, signal: status.termsig, stderr:)
      end

      # On any way out, a result, an error or Ctrl-C, the group is killed, the checker reaped and every end closed. A
      # second Ctrl-C or signal waits until that is done and is raised after, since none of it is slow after the KILL.
      def stop
        Thread.handle_interrupt(Object => :never) do
          next close unless @pid

          kill
          (@waiter || Process.detach(@pid)).join
          close
        end
      end

      def close = @ends.each { it.close unless it.closed? }

      private

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def pipe = IO.pipe.tap { @ends.concat(it) }

      def expire(timeout)
        signal('TERM')
        @waiter.join(KILL_GRACE)
        signal('KILL')
        @waiter.join
        Outcome.new(timed_out: timeout)
      end

      def kill = %w[TERM KILL].each { signal(it) }

      def signal(name)
        Process.kill(name, -@pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      # A checker that exits without reading breaks the pipe, and its exit status decides.
      def writer(envelope)
        Thread.new do
          @input.write(envelope)
        rescue IOError, Errno::EPIPE
          nil
        ensure
          @input.close unless @input.closed?
        end
      end

      def drain(io)
        Thread.new do
          nil while io.readpartial(CHUNK)
        rescue IOError
          nil
        end
      end

      def keep(io)
        Thread.new do
          while (chunk = io.readpartial(CHUNK))
            @cut ||= @kept.bytesize + chunk.bytesize > KEEP
            @kept << chunk.byteslice(0, KEEP - @kept.bytesize) unless @kept.bytesize >= KEEP
          end
        rescue IOError
          nil
        end
      end

      def stderr
        text = String.new(@kept, encoding: Encoding::UTF_8).scrub.rstrip
        @cut ? "#{text}\n(cut at #{KEEP} bytes)" : text
      end
    end
  end
end
