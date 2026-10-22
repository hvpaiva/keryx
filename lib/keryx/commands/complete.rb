# frozen_string_literal: true

require_relative '../cli/command'

module Keryx
  module Commands
    class Complete < CLI::Command
      VALUE_OPTIONS = %w[--as -o --output -f --file --within --timeout --role].freeze
      GLOBAL_FLAGS = %w[--as --color --help --version].freeze
      OUTPUTS = %w[table json].freeze
      POSITIONALS = { 'send' => :addresses, 'ask' => :addresses, 'join' => :addresses, 'ring' => :addresses,
                      'read' => :my_messages, 'reply' => :my_messages, 'wait' => :my_open_requests,
                      'completion' => :shells, 'hook' => :events, 'help' => :command_names }.freeze

      define '__complete', section: 'Other Commands', arguments: 'WORDS...', max: nil, hidden: true,
                           summary: 'Print completion candidates for the given words'

      def self.raw? = true

      # Never fails: an error here would print inside the user's command line.
      def call(words)
        current = words.last.to_s
        before = joined(words[0...-1])
        @as = acting_as(before)
        terminal.puts(candidates(before, current).select { matches?(it, current) }.uniq)
        nil
      rescue StandardError
        nil
      end

      private

      def candidates(before, current)
        option = before.last.to_s.delete_suffix('=')
        return value_candidates(option) if VALUE_OPTIONS.include?(option)

        command, positionals = parse(before)
        return flags(command) if current.start_with?('-')
        return command_names unless command

        positional_candidates(command.spec.name, positionals.size)
      end

      def parse(words)
        command = nil
        positionals = []
        words.each_with_index do |word, index|
          next if word.start_with?('-') || (index.positive? && VALUE_OPTIONS.include?(words[index - 1]))

          command ? positionals << word : command = Commands::ALL.find { it.spec.name == word }
        end
        [command, positionals]
      end

      # Bash breaks --as=NAME into --as, = and NAME, as COMP_WORDBREAKS says, so the pieces are joined again.
      def joined(words)
        words.each_with_object([]) do |word, joined|
          if (word == '=' && joined.last.to_s.start_with?('--')) || joined.last.to_s.match?(/\A--[a-z-]+=\z/)
            joined[-1] += word
          else
            joined << word
          end
        end
      end

      def acting_as(words)
        name = nil
        words.each_with_index do |word, index|
          name = words[index + 1] if word == '--as'
          name = word.delete_prefix('--as=') if word.start_with?('--as=')
        end
        name
      end

      def me = @as || app.me

      def flags(command)
        return GLOBAL_FLAGS unless command

        parser = OptionParser.new
        command.new(terminal) { app }.define_options(parser)
        GLOBAL_FLAGS + parser.top.list.flat_map { [*it.short, *it.long] }
      end

      def value_candidates(option)
        case option
        when '--as' then app.store.address_names
        when '-o', '--output' then OUTPUTS
        else []
        end
      end

      def positional_candidates(name, index)
        source = POSITIONALS[name]
        source && (index.zero? || name == 'ring') ? send(source) : []
      end

      def addresses = app.store.address_names

      def my_messages
        app.store.mailbox(me).sort_by { it.state == :unread ? 0 : 1 }.map { it.message.id }
      end

      def my_open_requests
        app.roster.open_requests.map { it.last.message }.select { it.from == app.full(me) }.map(&:id)
      end

      def shells = Completion::SHELLS

      def events = Hook::EVENTS

      def command_names = Commands::ALL.reject { it.spec.hidden }.map { it.spec.name }

      def matches?(candidate, current) = candidate.upcase.start_with?(current.upcase)
    end
  end
end
