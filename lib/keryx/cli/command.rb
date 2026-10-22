# frozen_string_literal: true

require 'json'
require_relative '../duration'
require_relative '../error'
require_relative 'message_view'

module Keryx
  module CLI
    class Command
      Spec = Data.define(:name, :summary, :section, :arguments, :description, :min, :max, :examples, :hidden)
      Example = Data.define(:comment, :line)
      FORMATS = %w[table json].freeze

      class << self
        attr_reader :spec

        def raw? = false

        def define(name, summary:, section:, arguments: '', description: nil, min: 0, max: 0, examples: [],
                   hidden: false)
          @spec = Spec.new(name:, summary:, section:, arguments:, description: description || "#{summary}.",
                           min:, max:, examples: examples.map { Example.new(*it) }, hidden:)
        end
      end

      attr_reader :options

      def initialize(terminal, &app)
        @terminal = terminal
        @app_factory = app
        @options = {}
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

      def print_json(data) = terminal.puts(JSON.pretty_generate(data))

      def show_message(message)
        json? ? print_json(message.record) : terminal.puts(MessageView.render(terminal, message, app.now))
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
