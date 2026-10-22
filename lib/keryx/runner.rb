# frozen_string_literal: true

require 'open3'

module Keryx
  class Runner
    Result = Data.define(:out, :err, :success)
    DEFAULT_TIMEOUT = 10
    KILL_GRACE = 1

    Done = Data.define(:result) do
      def done?(**) = true

      def stop = nil
    end

    def initialize(timeout: DEFAULT_TIMEOUT)
      @timeout = timeout
    end

    def call(argv, env: {}, input: nil)
      job = start(argv, env:, input:)
      return job.result if job.done?(within: @timeout)

      job.stop
      Result.new(out: '', err: "#{argv.first} did not finish within #{@timeout}s", success: false)
    rescue Interrupt
      job&.stop
      raise
    end

    def start(argv, env: {}, input: nil)
      Job.new(*Open3.popen3(env, *argv, pgroup: true), input)
    rescue SystemCallError => e
      Done.new(Result.new(out: '', err: "#{argv.first}: #{e.message}", success: false))
    end

    class Job
      def initialize(stdin, stdout, stderr, waiter, input)
        @waiter = waiter
        @pipes = [stdout, stderr]
        @out = reader(stdout)
        @err = reader(stderr)
        @threads = [waiter, @out, @err, writer(stdin, input)]
      end

      def done?(within: 0)
        deadline = now + within
        @threads.all? { it.join([deadline - now, 0].max) }
      end

      def result
        @result ||= Result.new(out: @out.value, err: @err.value, success: @waiter.value.success?).tap { close }
      end

      def stop
        signal_group('TERM')
        @waiter.join(KILL_GRACE)
        signal_group('KILL')
        close
      end

      private

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def close = @pipes.each { it.close unless it.closed? }

      def reader(io)
        Thread.new do
          io.read
        rescue IOError
          ''
        end
      end

      def writer(io, input)
        Thread.new do
          io.write(input) if input
        rescue IOError, Errno::EPIPE
          nil
        ensure
          io.close unless io.closed?
        end
      end

      def signal_group(signal)
        Process.kill(signal, -@waiter.pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end
  end
end
