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
    # Parses the command line, runs one command and turns every outcome into an exit status, so
    # no exception reaches the user as a backtrace.
    class Dispatcher
      PROGRAM = 'keryx'
      DESCRIPTION = "keryx carries messages between AI coding agent sessions.\n\n" \
                    'Each session joins an address, such as rev-1, and keeps it while it runs. A message is ' \
                    "written to the recipient's mailbox first and then announced to the session holding the " \
                    "address, through its harness's own channel when there is one."
      SIGINT_STATUS = 130
      DEBUG_VARIABLE = 'KERYX_DEBUG'
      COLOR_VARIABLE = 'KERYX_COLOR'

      # `app_factory` is called with the parsed global options the first time a command needs
      # the mailboxes.
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

      # Color is settled before the command is looked up, so even that error is painted as asked.
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

        arguments = parse(argv, command_parser(command, globals), :permute!)
        return command_help(command) if globals[:help]

        check_arity(command.spec, arguments)
        return help_command(arguments) if @current == 'help'

        command.call(arguments) || 0
      end

      # `keryx help ask` prints what `keryx ask --help` does.
      def help_command(arguments)
        return root_help if arguments.empty?

        command_help(find(arguments.first).new(@terminal) { raise Error, 'help reads no mailbox' })
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
          parser.on('--as NAME', 'Act as this address instead of the one this session holds') { globals[:as] = it }
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

      def help = Help.new(@terminal, program: PROGRAM, description: DESCRIPTION)

      def root_help
        @terminal.puts(help.root(@commands, global_parser({})))
        0
      end

      # The command's own options and the global ones are listed apart.
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
        @terminal.warn("#{@terminal.paint_err(:error, 'error:')} unexpected #{error.class}: #{error.message}")
        @terminal.warn(*Array(error.backtrace).map { "    #{it}" }) unless @terminal.env[DEBUG_VARIABLE].to_s.empty?
        1
      end

      # A damaged message file is skipped, never fatal, and said once at the end.
      def warn_problems
        Array(@app&.problems).uniq.each do |problem|
          @terminal.warn("#{@terminal.paint_err(:warning, 'warning:')} #{Text.plain(problem)}")
        end
      end
    end
  end
end
