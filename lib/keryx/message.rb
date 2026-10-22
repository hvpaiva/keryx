# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'error'
require_relative 'text'

module Keryx
  Message = Data.define(:id, :kind, :from, :to, :thread, :in_reply_to, :created_at, :due_at, :body)

  # One message as written to a mailbox. `from` and `to` are full addresses, `thread` is the id
  # of the message that opened the conversation, and `due_at` is set on requests asked with a
  # deadline. A message never changes once written; what happened to it is read from where its
  # file is and from the replies that point at it.
  class Message
    KINDS = %w[message request reply].freeze
    FORMAT_VERSION = 1
    MAX_BODY_BYTES = 64 * 1024
    FIELDS = %w[id kind from to thread in_reply_to created_at due_at body].freeze

    def self.from_json(text)
      data = JSON.parse(text)
      raise Error, 'not a keryx message' unless data.is_a?(Hash) && data['keryx'] == FORMAT_VERSION

      build(data)
    rescue JSON::ParserError => e
      raise Error, "not valid JSON (#{e.message.lines.first.strip})"
    end

    def self.build(data)
      missing = %w[id kind from to thread created_at body] - data.compact.keys
      raise Error, "missing #{missing.join(', ')}" unless missing.empty?
      raise Error, "unknown kind #{data['kind'].inspect}" unless KINDS.include?(data['kind'])

      new(id: data['id'], kind: data['kind'], from: data['from'], to: data['to'], thread: data['thread'],
          in_reply_to: data['in_reply_to'], created_at: time(data['created_at']), due_at: time(data['due_at']),
          body: data['body'])
    end

    def self.time(text)
      text && Time.iso8601(text)
    rescue ArgumentError => e
      raise Error, "bad time: #{e.message}"
    end
    private_class_method :time

    def request? = kind == 'request'

    def reply? = kind == 'reply'

    def overdue?(now) = request? && !due_at.nil? && now > due_at

    # The first line with text, made safe for a terminal and cut to `width` characters.
    def summary(width = 60)
      line = body.each_line.map(&:strip).find { !it.empty? }.to_s
      line = Text.plain(line)
      line.size > width ? "#{line[0, width - 3]}..." : line
    end

    # The fields as JSON writes them, with string keys and ISO 8601 times.
    def record
      FIELDS.to_h { [it, public_send(it)] }.merge('created_at' => created_at.utc.iso8601,
                                                  'due_at' => due_at&.utc&.iso8601)
    end

    def to_json(*) = JSON.generate({ 'keryx' => FORMAT_VERSION, **record }, *)
  end
end
