# frozen_string_literal: true

require 'json'
require_relative '../cli/command'
require_relative '../stop_hook'

module Keryx
  module Commands
    class Hook < CLI::Command
      EVENTS = %w[stop].freeze
      CLAUDE_SETTINGS = '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "keryx hook stop"}]}]}}'

      define 'hook', section: 'Other Commands', arguments: 'EVENT', min: 1, max: 1,
                     summary: 'Run the keryx side of a harness hook',
                     description: "Run the keryx side of a harness hook. The one event is stop, for Claude Code's " \
                                  "Stop hook.\n\n" \
                                  'When the session is about to end its turn with unread mail, or with a request it ' \
                                  'read and never answered, the hook keeps the turn going once and names what is ' \
                                  'pending. Each message is reminded about once. Sessions that hold no address ' \
                                  "are left alone. Enable it in Claude Code's settings.json:\n\n  " \
                                  "#{CLAUDE_SETTINGS}\n\n" \
                                  'The hook never fails the session: a problem in keryx is printed on standard ' \
                                  'error and the turn ends normally.',
                     examples: [['What Claude Code runs at the end of each turn', 'hook stop < payload.json']]

      def call(arguments)
        raise UsageError, "unknown event #{arguments.first.inspect}; the events are #{EVENTS.join(', ')}" unless
          EVENTS.include?(arguments.first)

        decide
      end

      private

      def decide
        input = terminal.input.read.to_s
        payload = input.strip.empty? ? {} : JSON.parse(input)
        decision = StopHook.new(store: app.store, herdr: app.herdr, caller: app.caller).decide(payload)
        terminal.puts(JSON.generate(decision)) if decision
        nil
      rescue Keryx::Error, JSON::ParserError, SystemCallError => e
        terminal.warn("keryx hook stop: #{e.message}")
        nil
      end
    end
  end
end
