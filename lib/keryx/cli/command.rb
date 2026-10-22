# frozen_string_literal: true

require 'json'
require_relative '../duration'
require_relative '../error'
require_relative 'message_view'

module Keryx
  module CLI
    # A command declares its name, arguments and options; the Dispatcher parses the line, prints
    # help and calls `call` with the positional arguments. `call` returns the exit status, or nil
    # for success, and raises Keryx::Error to fail.
    class Command
      Spec = Data.define(:name, :summary, :section, :arguments, :description, :min, :max, :examples, :hidden)
      Example = Data.define(:comment, :line)
      FORMATS = %w[table json].freeze

      class << self
        attr_reader :spec

        # A raw command receives the words after its name untouched, with no option parsing.
        def raw? = false

        def define(name, summary:, section:, arguments: '', description: nil, min: 0, max: 0, examples: [],
                   hidden: false)
          @spec = Spec.new(name:, summary:, section:, arguments:, description: description || "#{summary}.",
                           min:, max:, examples: examples.map { Example.new(*it) }, hidden:)
        end
      end

      attr_reader :options

      # `app` is a block so a command that never needs the mailboxes never builds them.
      def initialize(terminal, &app)
        @terminal = terminal
        @app_factory = app
        @options = {}
      end

      def spec = self.class.spec

      # Subclasses add their switches here, storing values in `options`.
      def define_options(parser); end

      private

      def app = @app ||= @app_factory.call

      attr_reader :terminal

      def output_option(parser)
        description = "Output format: #{FORMATS.join(' or ')} (default table)"
        parser.on('-o', '--output FORMAT', FORMATS, description) { |format| options[:output] = format }
      end

      def json? = options[:output] == 'json'

      def print_json(data) = terminal.puts(JSON.pretty_generate(data))

      def show_message(message)
        json? ? print_json(message.record) : terminal.puts(MessageView.render(terminal, message, app.now))
      end

      def body_option(parser)
        parser.on('-f', '--file PATH', 'Read the text from PATH, or from standard input when PATH is -') do |path|
          options[:file] = path
        end
      end

      # The text comes from the argument, from --file, or from standard input when either is "-".
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
