# frozen_string_literal: true

require_relative '../cli/command'

module Keryx
  module Commands
    # The Dispatcher answers this one itself, since it owns the list of commands and the parsers.
    class Help < CLI::Command
      define 'help', section: 'Other Commands', arguments: '[COMMAND]', max: 1,
                     summary: 'Show help for keryx or for a command',
                     examples: [['Read about ask', 'help ask']]
    end
  end
end
