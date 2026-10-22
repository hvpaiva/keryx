# frozen_string_literal: true

require 'open3'

module Keryx
  class Runner
    Result = Data.define(:out, :err, :success)
    DEFAULT_TIMEOUT = 10
    KILL_GRACE = 1

    def initialize(timeout: DEFAULT_TIMEOUT)
      @timeout = timeout
    end

    def call(argv, env: {}, input: nil, timeout: @timeout)
      Open3.popen3(env, *argv, pgroup: true) { |*streams| run(argv.first, input, timeout, streams) }
    rescue SystemCallError => e
      Result.new(out: '', err: "#{argv.first}: #{e.message}", success: false)
    end

    private

    def run(program, input, timeout, (stdin, stdout, stderr, waiter))
      deadline = now + timeout
      out = reader(stdout)
      err = reader(stderr)
      writer(stdin, input)
      if done?(deadline, waiter, out, err)
        return Result.new(out: out.value, err: err.value, success: waiter.value.success?)
      end

      stop(waiter, stdout, stderr)
      Result.new(out: '', err: "#{program} did not finish within #{timeout}s", success: false)
    rescue Interrupt
      stop(waiter, stdout, stderr)
      raise
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def done?(deadline, *threads) = threads.all? { it.join([deadline - now, 0].max) }

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

    def stop(waiter, *pipes)
      signal_group('TERM', waiter.pid)
      waiter.join(KILL_GRACE)
      signal_group('KILL', waiter.pid)
      pipes.each { it.close unless it.closed? }
    end

    def signal_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
