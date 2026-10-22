# frozen_string_literal: true

require_relative '../cli/command'
require_relative '../cli/completion_scripts'

module Keryx
  module Commands
    class Completion < CLI::Command
      SHELLS = CLI::CompletionScripts::SHELLS

      define 'completion', section: 'Other Commands', arguments: 'SHELL', min: 1, max: 1,
                           summary: "Print shell completion code (#{SHELLS.join(', ')})",
                           description: "Print the completion code for SHELL, one of #{SHELLS.join(', ')}.\n\n" \
                                        'It completes commands, flags, the addresses on this machine and the ids ' \
                                        'of your messages.',
                           examples: [['Load completions in the current bash', 'completion bash | source /dev/stdin'],
                                      ['Install them for fish',
                                       'completion fish > ~/.config/fish/completions/keryx.fish']]

      def call(arguments)
        shell = arguments.first
        raise UsageError, "unknown shell #{shell.inspect}; choose one of #{SHELLS.join(', ')}" unless
          SHELLS.include?(shell)

        terminal.print(CLI::CompletionScripts.render(shell, CLI::Dispatcher::PROGRAM))
        nil
      end
    end
  end
end
