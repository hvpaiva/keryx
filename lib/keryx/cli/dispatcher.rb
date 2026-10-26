# frozen_string_literal: true

require 'did_you_mean'
require 'optparse'
require_relative '../error'
require_relative '../text'
require_relative '../version'
require_relative 'help'
require_relative 'style'

module Keryx
  module CLI
    class Dispatcher
      PROGRAM = 'keryx'
      DESCRIPTION = "keryx carries messages between AI coding agent sessions.\n\n" \
                    'Each session joins an address, such as rev-1, and keeps it while it runs. A message is ' \
                    "written to the recipient's mailbox first and then announced to the session holding the " \
                    "address, through its harness's own channel when there is one.\n\n" \
                    'A Codex session is rung only while herdr shows it in its pane, by its thread or its own ' \
                    "process, because Codex's shared server keeps a closed thread loaded for 30 minutes and runs " \
                    'whatever is queued for it with no one watching. A Codex session outside a herdr pane gets no ' \
                    "bell, and its mail waits in the mailbox.\n\n" \
                    '--as ADDRESS, or KERYX_AS, makes a command act as an address on this machine instead of the ' \
                    'one this session holds, and the address must exist and not be retired. MEMBER alone takes the ' \
                    'team of the address this session holds, or else the one team on this machine with that ' \
                    'member. An address from before team names is taken only written in full, as MEMBER@HOST, and ' \
                    'never by a short name. ADDRESS/SESSION acts as that session of the address while it is bound ' \
                    'to it. What a command sends with --as carries no context reading, since the session that runs ' \
                    'the command need not be the one that holds the address.'
      SIGINT_STATUS = 130
      DEBUG_VARIABLE = 'KERYX_DEBUG'
      COLOR_VARIABLE = 'KERYX_COLOR'
      ENVIRONMENT = [
        ['KERYX_HOME', 'Where the mailboxes live, instead of $XDG_STATE_HOME/keryx'],
        ['KERYX_HOST', 'The host part of addresses, instead of host in the config file'],
        ['KERYX_AS', 'Act as this address, like --as'],
        ['KERYX_SSH', 'The ssh command that reaches other machines, instead of ssh'],
        ['KERYX_REMOTE_COMMAND', 'How to run keryx on the other machine, instead of keryx'],
        ['CLAUDE_CONFIG_DIR', "Where Claude Code keeps its sessions' transcripts, instead of ~/.claude"],
        ['CODEX_HOME', "Where Codex keeps its threads' rollouts, instead of ~/.codex"],
        [COLOR_VARIABLE, 'auto, always or never, like --color'],
        ['NO_COLOR, FORCE_COLOR', 'The usual color switches, honored in auto mode'],
        [DEBUG_VARIABLE, 'Print a backtrace for unexpected errors']
      ].freeze
      FILES = [
        ['~/.config/keryx/config', 'Settings as key = value lines, under $XDG_CONFIG_HOME when set'],
        ['  host = NAME', "The host part of addresses, instead of the machine's name"]
      ].freeze
      EXIT_STATUSES = [
        ['0', 'Success'],
        ['1', 'An error, such as an unknown address or a damaged file'],
        ['2', 'A usage error, such as an unknown command or flag or a missing argument'],
        ['3', 'keryx wait or keryx spawn gave up before the reply or the join'],
        [SIGINT_STATUS.to_s, 'Interrupted']
      ].freeze

      def initialize(terminal, commands:, app_factory:)
        @terminal = terminal
        @commands = commands
        @app_factory = app_factory
      end

      def self.version_line = "#{PROGRAM} #{VERSION} (ruby #{RUBY_VERSION})"

      def run(argv)
        execute(argv.dup)
      rescue Errno::EPIPE
        0
      end

      private

      def execute(argv)
        route(argv)
      rescue Keryx::Error => e
        report(e)
      rescue Interrupt
        @terminal.err.write("\n")
        SIGINT_STATUS
      rescue StandardError => e
        unexpected(e)
      ensure
        warn_problems
      end

      def route(argv)
        globals = {}
        parse(argv, global_parser(globals), :order!)
        @terminal.colorize(color_mode(globals))
        return version if globals[:version]

        name = argv.shift
        name ? dispatch(find(name), argv, globals) : root_help
      end

      def dispatch(command_class, argv, globals)
        @current = command_class.spec.name
        command = command_class.new(@terminal) { app(globals) }
        return command.call(argv) || 0 if command_class.raw?

        argv, command.passthrough = split_passthrough(argv) if command.spec.passthrough
        arguments = parse(argv, command_parser(command, globals), :permute!)
        return command_help(command) if globals[:help]

        check_arity(command.spec, arguments)
        return help_command(arguments) if @current == 'help'

        command.call(arguments) || 0
      end

      def help_command(arguments)
        return root_help if arguments.empty?

        command_help(find(arguments.first).new(@terminal) { raise Error, 'help reads no mailbox' })
      end

      def split_passthrough(argv)
        index = argv.index('--') or return [argv, []]
        [argv[0...index], argv[(index + 1)..]]
      end

      def app(globals) = @app ||= @app_factory.call(globals)

      def find(name)
        command = @commands.find { it.spec.name == name }
        return command if command

        guesses = DidYouMean::SpellChecker.new(dictionary: visible_names).correct(name)
        hint = guesses.empty? ? '' : "\n\nDid you mean this?\n#{guesses.map { "\t#{it}" }.join("\n")}"
        raise UsageError, "unknown command #{name.inspect} for \"#{PROGRAM}\"#{hint}"
      end

      def visible_names = @commands.reject { it.spec.hidden }.map { it.spec.name }

      def parse(argv, parser, method)
        parser.public_send(method, argv)
      rescue OptionParser::ParseError => e
        raise UsageError, e.message
      end

      def global_parser(globals)
        OptionParser.new do |parser|
          parser.require_exact = true
          parser.on('--as ADDRESS', 'Act as this address instead of the one this session holds') { globals[:as] = it }
          color = 'Use color: auto, always or never (bare --color means always)'
          parser.on('--color[=WHEN]', Style::MODES, color) { |mode| globals[:color] = mode || 'always' }
          parser.on('-h', '--help', 'Show help') { globals[:help] = true }
          parser.on('-V', '--version', 'Show the version') { globals[:version] = true }
        end
      end

      def command_parser(command, globals)
        parser = global_parser(globals)
        command.define_options(parser)
        parser
      end

      def check_arity(spec, arguments)
        raise UsageError, "#{spec.name} takes at least #{spec.min} argument(s)" if arguments.size < spec.min
        return unless spec.max && arguments.size > spec.max

        raise UsageError, "unexpected argument #{arguments[spec.max].inspect}"
      end

      def color_mode(globals)
        mode = globals[:color] || @terminal.env[COLOR_VARIABLE].to_s
        return 'auto' if mode.empty?
        return mode if Style::MODES.include?(mode)

        raise UsageError, "#{COLOR_VARIABLE} must be one of #{Style::MODES.join(', ')}"
      end

      def help
        Help.new(@terminal, program: PROGRAM, description: DESCRIPTION,
                            notes: { 'Environment' => ENVIRONMENT, 'Files' => FILES, 'Exit Status' => EXIT_STATUSES })
      end

      def root_help
        @terminal.puts(help.root(@commands, global_parser({})))
        0
      end

      def command_help(command)
        own = OptionParser.new
        command.define_options(own)
        @terminal.puts(help.command(command.spec, own, global_parser({})))
        0
      end

      def version
        @terminal.puts(self.class.version_line)
        0
      end

      def report(error)
        @terminal.warn("#{@terminal.paint_err(:error, 'error:')} #{Text.plain(error.message, layout: true)}")
        @terminal.warn("Run '#{[PROGRAM, @current, '--help'].compact.join(' ')}' for usage.") if error.is_a?(UsageError)
        error.exit_status
      end

      def unexpected(error)
        @terminal.warn("#{@terminal.paint_err(:error, 'error:')} unexpected #{error.class}: " \
                       "#{Text.plain(error.message, layout: true)}")
        unless @terminal.env[DEBUG_VARIABLE].to_s.empty?
          @terminal.warn(*Array(error.backtrace).map { "    #{Text.plain(it)}" })
        end
        1
      end

      def warn_problems
        Array(@app&.take_problems).each { @terminal.warning(it) }
      end
    end
  end
end
