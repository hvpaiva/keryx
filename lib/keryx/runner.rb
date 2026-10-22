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

    def call(argv, env: {}, input: nil)
      Open3.popen3(env, *argv) do |stdin, stdout, stderr, waiter|
        out = reader(stdout)
        err = reader(stderr)
        writer(stdin, input)
        next Result.new(out: out.value, err: err.value, success: waiter.value.success?) if waiter.join(@timeout)

        stop(waiter)
        Result.new(out: '', err: "#{argv.first} did not finish within #{@timeout}s", success: false)
      end
    rescue SystemCallError => e
      Result.new(out: '', err: "#{argv.first}: #{e.message}", success: false)
    end

    private

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

    def stop(waiter)
      Process.kill('TERM', waiter.pid)
      Process.kill('KILL', waiter.pid) unless waiter.join(KILL_GRACE)
    rescue Errno::ESRCH
      nil
    end
  end
end
