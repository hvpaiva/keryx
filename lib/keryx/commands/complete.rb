# frozen_string_literal: true

require_relative '../cli/command'

module Keryx
  module Commands
    class Complete < CLI::Command
      VALUE_OPTIONS = %w[--as -o --output -f --file --within --timeout --role --harness --pane --socket --split --tab
                         --workspace --cwd --model --effort --prompt --ceiling --re --id --thread --to].freeze
      GLOBAL_FLAGS = %w[--as --color --help --version].freeze
      OUTPUTS = %w[table json].freeze
      OPTION_NAME = /\A--[a-z][a-z-]*\z/
      POSITIONALS = { 'send' => :addresses, 'ask' => :addresses, 'join' => :addresses, 'ring' => :addresses,
                      'retire' => :addresses, 'purge' => :retired, 'history' => :retired, 'read' => :my_messages,
                      'reply' => :my_messages,
                      'wait' => :my_open_requests, 'withdraw' => :my_open_requests,
                      'completion' => :shells, 'hook' => :events, 'wiring' => :harnesses,
                      'help' => :command_names }.freeze

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
        return [] if before.include?('--')

        option = before.last.to_s.delete_suffix('=')
        return value_candidates(option) if VALUE_OPTIONS.include?(option)

        command, positionals = parse(before)
        return flags(command) if current.start_with?('-')
        return command_names unless command
        # With --re, the one argument send takes is the text.
        return [] if before.any? { it == '--re' || it.start_with?('--re=') }

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
          if glued?(joined.last.to_s, word)
            joined[-1] += word
          else
            joined << word
          end
        end
      end

      def glued?(last, word)
        return OPTION_NAME.match?(last) if word == '='

        last.end_with?('=') && OPTION_NAME.match?(last.chomp('='))
      end

      # The value of the last --as before the word being completed, or nil while that value is the word.
      def acting_as(words)
        name = nil
        words.each_with_index do |word, index|
          name = words[index + 1] if word == '--as'
          name = word.delete_prefix('--as=') if word.start_with?('--as=')
        end
        name unless name.to_s.empty?
      end

      # The incarnation the command acts as, with --as on the line resolved as the command resolves it, so a session
      # address names the session join --force displaced rather than the holder.
      def me = @as ? app.identity.current(as: @as) : app.me

      def flags(command)
        return GLOBAL_FLAGS unless command

        parser = OptionParser.new
        command.new(terminal) { app }.define_options(parser)
        GLOBAL_FLAGS + parser.top.list.flat_map { [*it.short, *it.long] }
      end

      def value_candidates(option)
        case option
        when '--as', '--to' then addresses
        when '-o', '--output' then OUTPUTS
        when '--harness' then Harness::KINDS
        when '--split' then Spawn::DIRECTIONS
        when '--re' then my_requests
        else []
        end
      end

      def positional_candidates(name, index)
        source = POSITIONALS[name]
        source && (index.zero? || name == 'ring') ? send(source) : []
      end

      # Every address here, and the bare members of the team the command acts in, which resolve to it.
      def addresses
        named = app.store.current_names.map { Address.from_key(it, host: app.host) }
        team = own_team
        named.select { it.team == team }.map(&:member) + named.map(&:key)
      end

      def own_team
        own = (@as ? me : app.own_address)&.then { Address.from_name(it, host: app.host) }
        own.team unless own.nil? || own.reserved?
      end

      # The retired addresses here, which keryx history reads; a folder from before team names is left out.
      def retired = app.store.address_names.select { app.store.retired?(it) }

      def my_messages
        app.store.mailbox(me).sort_by { it.state == :unread ? 0 : 1 }.map { it.message.id }
      end

      def my_requests = app.store.listed(me, app.roster.open_requests).map { it.message.id }

      def my_open_requests
        open = app.roster.open_requests.map { it.last.message.id }
        app.store.sent_requests(me, by_id: false).map { it.last.id } & open
      end

      def shells = Completion::SHELLS

      def events = Hook::EVENTS

      def harnesses = Harness::KINDS

      def command_names = Commands::ALL.reject { it.spec.hidden }.map { it.spec.name }

      def matches?(candidate, current) = candidate.upcase.start_with?(current.upcase)
    end
  end
end
