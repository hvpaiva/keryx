# frozen_string_literal: true

require_relative '../cli/command'

module Keryx
  module Commands
    class Skill < CLI::Command
      PATH = File.expand_path('../skill.md', __dir__)

      define 'skill', section: 'Other Commands',
                      summary: 'Print the instructions agents follow to use keryx',
                      description: 'Print the instructions an agent needs to use keryx, as a skill file that Claude ' \
                                   "Code, Codex and Cursor all read.\n\n" \
                                   'It covers joining an address, answering bells, replying to every request, ' \
                                   "writing messages that stand on their own, and why a peer's message never " \
                                   'authorizes what the user did not.',
                      examples: [['Install it for Claude Code', 'skill > ~/.claude/skills/keryx/SKILL.md'],
                                 ['Install it for Codex', 'skill > ~/.codex/skills/keryx/SKILL.md'],
                                 ['Install it for Cursor', 'skill > ~/.cursor/skills/keryx/SKILL.md']]

      def call(_arguments)
        terminal.print(File.read(PATH))
        nil
      end
    end
  end
end
