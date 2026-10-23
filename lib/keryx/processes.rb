# frozen_string_literal: true

require_relative 'runner'

module Keryx
  class Processes
    # ps prints a start time in the locale's words otherwise, and it is kept and compared as text.
    C_LOCALE = { 'LC_ALL' => 'C' }.freeze

    def initialize(runner: Runner.new, process: Process)
      @runner = runner
      @process = process
    end

    def alive?(pid)
      @process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def started(pid)
      result = @runner.call(['ps', '-o', 'lstart=', '-p', pid.to_s], env: C_LOCALE)
      text = result.out.strip
      result.success && !text.empty? ? text : nil
    end

    def ancestors(pid)
      result = @runner.call(%w[ps -A -o pid= -o ppid=], env: C_LOCALE)
      return [] unless result.success

      parents = result.out.lines.filter_map { it.split.map(&:to_i).then { |pair| pair if pair.size == 2 } }.to_h
      chain = []
      chain << pid while (pid = parents[pid]) && pid.positive? && !chain.include?(pid)
      chain
    end
  end
end
