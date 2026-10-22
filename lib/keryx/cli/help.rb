# frozen_string_literal: true

require 'optparse'

module Keryx
  module CLI
    class Help
      SECTIONS = ['Session Commands', 'Mail Commands', 'Overview Commands', 'Other Commands'].freeze
      SUMMARY_WIDTH = 26
      DEFAULT_WIDTH = 80
      MAX_WIDTH = 100

      def initialize(terminal, program:, description:, notes: {})
        @terminal = terminal
        @program = program
        @description = description
        @notes = notes
        @width = [terminal.columns || DEFAULT_WIDTH, MAX_WIDTH].min
      end

      def root(commands, globals)
        [prose(@description), usage("#{@program} [options] <command> [arguments]"), *command_sections(commands),
         options(globals, 'Global Options'), *@notes.map { |title, rows| definitions(title, rows) },
         "Run '#{@program} <command> --help' for more about a command."].join("\n\n")
      end

      def command(spec, parser, globals)
        line = [@program, spec.name, '[options]', spec.arguments].reject(&:empty?).join(' ')
        [prose(spec.description), usage(line), options(parser, 'Options'), options(globals, 'Global Options'),
         examples(spec.examples)].compact.join("\n\n")
      end

      private

      def command_sections(commands)
        visible = commands.reject { it.spec.hidden }
        width = visible.map { it.spec.name.size }.max
        SECTIONS.filter_map do |section|
          entries = visible.select { it.spec.section == section }
          next if entries.empty?

          "#{header(section)}\n#{entries.map { "  #{it.spec.name.ljust(width)}   #{it.spec.summary}" }.join("\n")}"
        end
      end

      def header(text) = @terminal.paint(:header, "#{text}:")

      def definitions(title, rows)
        "#{header(title)}\n#{rows.map { |term, text| "  #{term.ljust(SUMMARY_WIDTH)} #{text}" }.join("\n")}"
      end

      def usage(line) = "#{header('Usage')}\n  #{line}"

      def options(parser, title)
        parser.summary_indent = '  '
        parser.summary_width = SUMMARY_WIDTH
        lines = []
        parser.summarize { lines << it.chomp }
        lines.empty? ? nil : "#{header(title)}\n#{lines.join("\n")}"
      end

      def examples(examples)
        return nil if examples.empty?

        blocks = examples.map do |example|
          "  #{@terminal.paint(:comment, "# #{example.comment}")}\n  #{@terminal.paint(:command, @program)} " \
            "#{example.line}"
        end
        "#{header('Examples')}\n#{blocks.join("\n\n")}"
      end

      def prose(text)
        text.split("\n\n").map do |paragraph|
          paragraph.start_with?('  ') ? paragraph : wrap(paragraph.tr("\n", ' '))
        end.join("\n\n")
      end

      def wrap(text)
        text.split.each_with_object([]) do |word, lines|
          if lines.empty? || lines.last.size + 1 + word.size > @width
            lines << word
          else
            lines[-1] = "#{lines.last} #{word}"
          end
        end.join("\n")
      end
    end
  end
end
