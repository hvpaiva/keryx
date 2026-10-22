# frozen_string_literal: true

require 'io/console'
require 'stringio'
require_relative 'style'

module Keryx
  module CLI
    class Terminal
      attr_reader :out, :err, :input, :env, :style, :err_style

      def self.system
        new(out: $stdout, err: $stderr, input: $stdin, env: ENV)
      end

      def initialize(out:, err:, input: StringIO.new, env: {})
        @out = out
        @err = err
        @input = input
        @env = env
        @closed = {}
        colorize('auto')
      end

      def colorize(mode)
        @style = Style.for(mode, tty: tty?(out), env:)
        @err_style = Style.for(mode, tty: tty?(err), env:)
      end

      def puts(*lines) = write(:out) { out.puts(*lines) }

      def print(*parts) = write(:out) { out.print(*parts) }

      def warn(*lines) = write(:err) { err.puts(*lines) }

      def paint(role, text) = style.paint(role, text)

      def paint_err(role, text) = err_style.paint(role, text)

      def interactive_input? = tty?(input)

      def columns
        from_env = Integer(env['COLUMNS'].to_s, 10, exception: false)
        return from_env if from_env&.positive?
        return nil unless tty?(out) && out.respond_to?(:winsize)

        out.winsize[1].then { it.positive? ? it : nil }
      rescue SystemCallError
        nil
      end

      private

      def tty?(io) = io.respond_to?(:tty?) && io.tty?

      def write(stream)
        return if @closed[stream]

        yield
      rescue Errno::EPIPE
        @closed[stream] = true
      end
    end
  end
end
