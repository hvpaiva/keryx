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
      # The version of the fields of every -o json output; ARCHITECTURE.md says when it changes.
      SCHEMA = 1
      SCHEMA_HELP = 'The object -o json prints, or each object of the array it prints, starts with schema, the ' \
                    "version of its fields, #{SCHEMA} in this release: within a version fields are only added, and " \
                    'removing or renaming one, or changing its type or meaning, raises it.'.freeze
      JSON_ESCAPED = /[\x7F#{Text::INVISIBLE}]/
      # How Address spells the member and the team of an address.
      NAME_SPELLING = 'MEMBER and TEAM each start with a lowercase letter and run up to 32 lowercase letters, ' \
                      'digits and hyphens.'
      SESSION_SPELLING = 'SESSION is 6 characters of lowercase Crockford base32.'
      # How the commands that take an address read it.
      ADDRESS_FORMS = 'ADDRESS is MEMBER.TEAM@HOST, MEMBER.TEAM for an address on this machine, or MEMBER alone ' \
                      "for a member of the sender's own team. A sender with no team, such as a person at a " \
                      'terminal, names MEMBER alone only when exactly one team on this machine has that member. ' \
                      "#{NAME_SPELLING} HOST starts with a lowercase letter or a digit and runs up to 63 lowercase " \
                      'letters, digits and hyphens, with no dots. Two teams are reserved scopes: NAME.local is a ' \
                      "person at a terminal, and keryx.system is keryx's own notices. MEMBER@HOST, an address " \
                      'from before team names, is refused: keryx no longer writes to one or takes mail from one, ' \
                      'though the mail it left in a mailbox still reads.'.freeze
      # The same, for the commands that also reach one session of an address.
      ADDRESSING = "#{ADDRESS_FORMS} ADDRESS/SESSION reaches only that session of the address, and is refused once " \
                   "the session leaves. #{SESSION_SPELLING}".freeze

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
      def print_json(data)
        terminal.puts(JSON.pretty_generate(versioned(data)).gsub(JSON_ESCAPED) { format('\u%04x', it.ord) })
      end

      # An object, or each object of an array, so that a reader of a list finds the version in every element.
      def versioned(data)
        case data
        when Hash then { 'schema' => SCHEMA, **data }
        when Array then data.map { versioned(it) }
        else data
        end
      end

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
