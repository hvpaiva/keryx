# frozen_string_literal: true

require 'json'
require_relative 'address'
require_relative 'check_config'
require_relative 'checker'
require_relative 'identity'

module Keryx
  # The check keryx runs before it writes a message, sent here or received from another machine. The checker that
  # /etc/keryx/check names reads the envelope on stdin and accepts the message with exit 0 or refuses it with exit 1
  # and its reason on stderr; anything else fails, and a failure refuses the message too. A person's mail and keryx's
  # own notices are not checked, so a broken checker never silences the author or the courier.
  class Check
    Broken = CheckConfig::Broken
    VERSION = 1
    SEND = 'send'
    RECEIVE = 'receive'
    REFUSED = 'refused the message'
    SILENT = 'refused the message and gave no reason'

    def initialize(host:, config: CheckConfig.new, checker: Checker.new)
      @host = host
      @config = config
      @checker = checker
    end

    attr_reader :config

    # By the sender the message names, whoever runs the command.
    def exempt?(message)
      from = Address.parse(message.from)
      from.key == Identity::SYSTEM || from.team == Address::LOCAL
    end

    # The seconds a check of MESSAGE may take, 0 when the file is broken and the refusal runs nothing, or nil when no
    # check runs.
    def timeout_for(message)
      return if exempt?(message)

      @config.setup&.timeout
    rescue Broken
      0
    end

    # Why MESSAGE may not be written, or nil when it may. On receive the reason names this machine and fits one line,
    # since it travels back in a receipt.
    def refusal(message, event:, command:)
      return if exempt?(message)

      setup = @config.setup or return
      reason(@checker.call(setup, envelope(message, event, command)), setup, event)
    rescue Broken => e
      failed(e.message, event)
    end

    private

    def envelope(message, event, command)
      "#{JSON.generate({ 'check' => VERSION, 'event' => event, 'host' => @host, 'command' => command,
                         'message' => JSON.parse(message.to_json) })}\n"
    end

    def reason(outcome, setup, event)
      return if outcome.status&.zero?
      return refused(outcome.stderr, event) if outcome.status == 1

      failed(failure(outcome, setup.command), event)
    end

    def failure(outcome, command)
      return outcome.error if outcome.error
      return "#{command} did not finish within #{outcome.timed_out}s" if outcome.timed_out
      return "#{command} was killed by SIG#{Signal.signame(outcome.signal)}" if outcome.signal

      ["#{command} exited with status #{outcome.status}", outcome.stderr].reject(&:empty?).join(': ')
    end

    def refused(stderr, event)
      return "#{subject(event)} #{SILENT}" if stderr.empty?

      event == SEND ? "#{subject(event)} #{REFUSED}:\n#{stderr}" : "#{subject(event)} #{REFUSED}: #{line(stderr)}"
    end

    def failed(reason, event) = "#{subject(event)} failed: #{event == SEND ? reason : line(reason)}"

    def subject(event) = event == SEND ? 'the check' : "the check on #{@host}"

    def line(text) = text.split(/\s*\n\s*/).reject(&:empty?).join(' ')
  end
end
