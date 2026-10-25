# frozen_string_literal: true

require 'json'
require_relative '../duration'
require_relative '../error'
require_relative '../text'
require_relative 'message_view'

module Keryx
  module CLI
    class Command
      Spec = Data.define(:name, :summary, :section, :arguments, :description, :min, :max, :examples, :hidden,
                         :passthrough)
      Example = Data.define(:comment, :line)
      FORMATS = %w[table json].freeze
      JSON_ESCAPED = /[\x7F#{Text::INVISIBLE}]/
      # How the commands that take an address read it.
      ADDRESSING = 'ADDRESS is MEMBER.TEAM@HOST, MEMBER.TEAM for an address on this machine, or MEMBER alone for ' \
                   "a member of the sender's own team. A sender with no team, such as a person at a terminal, names " \
                   'MEMBER alone only when exactly one team on this machine has that member. ADDRESS/SESSION reaches ' \
                   'only that session of the address, and is refused once the session leaves.'

      class << self
        attr_reader :spec

        def raw? = false

        def define(name, summary:, section:, arguments: '', description: nil, min: 0, max: 0, examples: [],
                   hidden: false, passthrough: false)
          @spec = Spec.new(name:, summary:, section:, arguments:, description: description || "#{summary}.",
                           min:, max:, examples: examples.map { Example.new(*it) }, hidden:, passthrough:)
        end
      end

      attr_reader :options
      attr_accessor :passthrough

      def initialize(terminal, &app)
        @terminal = terminal
        @app_factory = app
        @options = {}
        @passthrough = []
      end

      def spec = self.class.spec

      def define_options(parser); end

      private

      def app = @app ||= @app_factory.call

      attr_reader :terminal

      def output_option(parser)
        description = "Output format: #{FORMATS.join(' or ')} (default table)"
        parser.on('-o', '--output FORMAT', FORMATS, description) { |format| options[:output] = format }
      end

      def json? = options[:output] == 'json'

      # JSON escapes C0 controls only; these characters occur only inside strings, so an escape keeps the value.
      def print_json(data) = terminal.puts(JSON.pretty_generate(data).gsub(JSON_ESCAPED) { format('\u%04x', it.ord) })

      def show_message(message, withdrawal = nil)
        return print_json(MessageView.record(message, withdrawal)) if json?

        terminal.puts(MessageView.render(terminal, message, app.now, withdrawal))
      end

      def body_option(parser)
        description = 'Read the text from PATH, or from standard input when PATH or TEXT is -'
        parser.on('-f', '--file PATH', description) { |path| options[:file] = path }
      end

      def body(text)
        raise UsageError, 'give the text as an argument or with --file, not both' if text && options[:file]

        source = text || options[:file]
        raise UsageError, 'missing the text: give it as an argument or with --file PATH' unless source
        return terminal.input.read.to_s if source == '-'

        text || read_file(source)
      end

      def read_file(path)
        File.read(path)
      rescue SystemCallError => e
        raise Error, "cannot read #{path}: #{e.message.sub(/ @ .*/, '')}"
      end

      def age(time) = Duration.short(app.now - time)
    end
  end
end
