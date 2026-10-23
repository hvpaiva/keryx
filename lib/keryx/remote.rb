# frozen_string_literal: true

require 'json'
require 'shellwords'
require_relative 'files'
require_relative 'runner'

module Keryx
  class Remote
    Answer = Data.define(:receipts, :error)
    TIMEOUT = 60
    CONNECT_TIMEOUT = 10

    def self.from_env(env, runner: Runner.new(timeout: TIMEOUT))
      ssh = env['KERYX_SSH'].to_s.strip
      command = env['KERYX_REMOTE_COMMAND'].to_s.strip
      new(ssh: Shellwords.split(ssh.empty? ? 'ssh' : ssh), command: command.empty? ? 'keryx' : command, runner:)
    end

    def initialize(ssh: ['ssh'], command: 'keryx', runner: Runner.new(timeout: TIMEOUT))
      @ssh = ssh
      @command = command
      @runner = runner
    end

    def deliver(host, messages)
      argv = [*@ssh, '-o', 'BatchMode=yes', '-o', "ConnectTimeout=#{CONNECT_TIMEOUT}", host, "#{@command} __receive"]
      result = @runner.call(argv, input: messages.map { "#{it.to_json}\n" }.join)
      return Answer.new(receipts: {}, error: failure(host, result)) unless result.success

      Answer.new(receipts: receipts(result.out), error: nil)
    end

    private

    def receipts(out)
      out.each_line.filter_map do |line|
        receipt = JSON.parse(line)
        [receipt['id'], usable(receipt)] if receipt.is_a?(Hash) && receipt.values_at('id', 'status').all?(String)
      rescue JSON::ParserError
        nil
      end.to_h
    end

    # A field the other machine got wrong is left out, so a bad bell never hides that the message arrived.
    def usable(receipt) = receipt.except(*Files.bad_options(receipt))

    def failure(host, result)
      result.err.lines.map(&:strip).reject(&:empty?).last || "#{@ssh.first} to #{host} failed"
    end
  end
end
