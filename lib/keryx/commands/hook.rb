# frozen_string_literal: true

require 'json'
require_relative '../cli/command'
require_relative '../harness'
require_relative '../stop_hook'
require_relative '../text'

module Keryx
  module Commands
    class Hook < CLI::Command
      EVENTS = %w[stop].freeze

      define 'hook', section: 'Other Commands', arguments: 'EVENT', min: 1, max: 1,
                     summary: 'Run the keryx side of a harness hook',
                     description: 'Run the keryx side of a harness hook. The one event is stop, which Claude Code, ' \
                                  "Codex and Cursor run when a session is about to end its turn.\n\n" \
                                  'When the session has unread mail, or a request it read and never answered, the ' \
                                  'hook keeps the turn going once and names what is pending, leaving out a request ' \
                                  'its sender withdrew and one the session took with keryx send --re, whose work ' \
                                  'goes on. Each message is ' \
                                  'reminded about once, and again only when the hook was cut off before it ' \
                                  'answered. Sessions that hold no address are left alone. Claude ' \
                                  "Code's settings.json and Codex's hooks.json enable it with\n\n  " \
                                  "#{Harness.hooks_line('claude')}\n\n" \
                                  "and Cursor's hooks.json with\n\n  " \
                                  "#{Harness.hooks_line('cursor')}\n\n" \
                                  "Codex runs a new hook only after you trust it in /hooks. 'keryx wiring HARNESS' " \
                                  'prints the entry and the files it goes in, with the rest of what a launcher ' \
                                  "gives a session.\n\n" \
                                  'The hook never fails the session. A problem in keryx is printed on standard ' \
                                  'error and the turn ends normally.',
                     examples: [['What the harness runs at the end of each turn', 'hook stop < payload.json']]

      def call(arguments)
        raise UsageError, "unknown event #{arguments.first.inspect}; the events are #{EVENTS.join(', ')}" unless
          EVENTS.include?(arguments.first)

        decide
      end

      private

      def decide
        input = terminal.input.read.to_s
        payload = input.strip.empty? ? {} : JSON.parse(input)
        raise Error, 'the payload is not a JSON object' unless payload.is_a?(Hash)

        StopHook.new(store: app.store, herdr: app.herdr, caller: app.caller, meter: app.meter)
                .decide(payload) { emit(it) }
        nil
      rescue Keryx::Error, JSON::ParserError, SystemCallError => e
        terminal.warn("keryx hook stop: #{Text.plain(e.message, layout: true)}")
        nil
      end

      def emit(decision)
        terminal.out.puts(JSON.generate(decision))
        terminal.out.flush
      end
    end
  end
end
