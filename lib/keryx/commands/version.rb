# frozen_string_literal: true

require_relative '../cli/command'

module Keryx
  module Commands
    class Version < CLI::Command
      define 'version', section: 'Other Commands',
                        summary: 'Print the version of keryx',
                        description: 'Print the version of keryx and of the Ruby running it.',
                        examples: [['Print the version', 'version']]

      def call(_arguments)
        terminal.puts(CLI::Dispatcher.version_line)
        nil
      end
    end
  end
end
