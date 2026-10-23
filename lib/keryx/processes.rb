# frozen_string_literal: true

require 'rbconfig'
require_relative 'runner'

module Keryx
  class Processes
    C_LOCALE = { 'LC_ALL' => 'C' }.freeze
    # ps prints a start time in the locale's words and the caller's time zone otherwise.
    PS_START = { 'LC_ALL' => 'C', 'TZ' => 'UTC0' }.freeze
    # Field 22 of /proc/PID/stat, counted from the state that follows the command name.
    START_FIELD = 19

    def initialize(runner: Runner.new, process: Process, proc_root: '/proc', host_os: RbConfig::CONFIG['host_os'])
      @runner = runner
      @process = process
      @proc_root = proc_root
      @linux = host_os.start_with?('linux')
    end

    def alive?(pid)
      @process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # Text that stays the same for the life of a process, kept and compared as it is. Linux gives the clock tick
    # since boot at which the process started, which no time zone or step of the wall clock moves; Linux's ps
    # derives its start time from the wall clock, but macOS's prints the time stored when the process started.
    def started(pid) = @linux ? tick_started(pid) : ps_started(pid)

    # Only the variables asked for, since another process's environment may hold secrets. Linux alone shows it.
    def environment(pid, names)
      return unless @linux && pid.is_a?(Integer)

      entries = File.binread(File.join(@proc_root, pid.to_s, 'environ')).split("\0").map { it.split('=', 2) }
      entries.filter_map do |name, value|
        text = String.new(value.to_s, encoding: Encoding::UTF_8)
        [name, text] if names.include?(name) && text.valid_encoding?
      end.to_h
    rescue SystemCallError
      nil
    end

    def ancestors(pid)
      result = @runner.call(%w[ps -A -o pid= -o ppid=], env: C_LOCALE)
      return [] unless result.success

      parents = result.out.lines.filter_map { it.split.map(&:to_i).then { |pair| pair if pair.size == 2 } }.to_h
      chain = []
      chain << pid while (pid = parents[pid]) && pid.positive? && !chain.include?(pid)
      chain
    end

    private

    # The command name in field 2 may hold spaces and parentheses, so the fields are counted after its last ") ".
    def tick_started(pid)
      return unless pid.is_a?(Integer)

      _name, separator, fields = File.binread(File.join(@proc_root, pid.to_s, 'stat')).rpartition(') ')
      tick = fields.split[START_FIELD] unless separator.empty?
      tick if tick&.match?(/\A\d+\z/)
    rescue SystemCallError
      nil
    end

    def ps_started(pid)
      result = @runner.call(['ps', '-o', 'lstart=', '-p', pid.to_s], env: PS_START)
      text = result.out.strip
      result.success && !text.empty? ? text : nil
    end
  end
end
