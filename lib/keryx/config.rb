# frozen_string_literal: true

require_relative 'error'
require_relative 'files'

module Keryx
  class Config
    include Files

    KEYS = %w[host].freeze
    Setting = Data.define(:value, :line)

    attr_reader :path, :problems

    def initialize(path)
      @path = path
      @problems = []
    end

    def host = settings['host']

    private

    def settings = @settings ||= parse(String.new(read, encoding: Encoding::UTF_8))

    def read
      read_regular(path) or raise Error, "cannot read #{path}: not a regular file"
    rescue Errno::ENOENT
      ''
    rescue SystemCallError => e
      raise Error, "cannot read #{path}: #{e.message.sub(/ @ .*/, '')}"
    end

    def parse(text)
      text.each_line.with_index(1).each_with_object({}) do |(line, number), settings|
        key, value = setting(line, number)
        next unless key

        earlier = settings[key]
        problem(number, "#{key} is set again, after line #{earlier.line}; the last one wins") if earlier
        settings[key] = Setting.new(value:, line: number)
      end
    end

    def setting(line, number)
      return problem(number, 'not valid UTF-8, ignored') unless line.valid_encoding?

      line = line.strip
      entry(line, number) unless line.empty? || line.start_with?('#')
    end

    def entry(line, number)
      key, separator, value = line.partition('=').map(&:strip)
      return problem(number, 'expected key = value, ignored') if [key, separator, value].any?(&:empty?)
      return problem(number, "unknown key #{key.inspect}, ignored") unless KEYS.include?(key)

      [key, value]
    end

    def problem(number, text)
      @problems << "#{path}:#{number}: #{text}"
      nil
    end
  end
end
