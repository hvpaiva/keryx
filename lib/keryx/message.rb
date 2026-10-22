# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'error'
require_relative 'text'
require_relative 'ulid'

module Keryx
  Message = Data.define(:id, :kind, :from, :to, :thread, :in_reply_to, :created_at, :due_at, :body)

  class Message
    KINDS = %w[message request reply].freeze
    FORMAT_VERSION = 1
    MAX_BODY_BYTES = 64 * 1024
    FIELDS = %w[id kind from to thread in_reply_to created_at due_at body].freeze
    ADDRESS = /\A[a-z][a-z0-9-]{0,31}@[a-z0-9][a-z0-9-]{0,62}\z/

    def self.from_json(text)
      data = JSON.parse(text)
      raise Error, 'not a keryx message' unless data.is_a?(Hash) && data['keryx'] == FORMAT_VERSION

      build(data)
    rescue JSON::ParserError => e
      raise Error, "not valid JSON (#{e.message.lines.first.strip})"
    end

    def self.build(data)
      check_fields(data)
      new(id: data['id'], kind: data['kind'], from: data['from'], to: data['to'], thread: data['thread'],
          in_reply_to: data['in_reply_to'], created_at: time(data['created_at']), due_at: time(data['due_at']),
          body: data['body'])
    end

    def self.check_fields(data)
      missing = %w[id kind from to thread created_at body] - data.compact.keys
      raise Error, "missing #{missing.join(', ')}" unless missing.empty?
      raise Error, "unknown kind #{data['kind'].inspect}" unless KINDS.include?(data['kind'])

      check_identity(data)
      check_body(data['body'])
    end

    # Bells and hook reminders repeat these fields into other sessions' context.
    def self.check_identity(data)
      %w[id thread].each { raise Error, "bad #{it} #{data[it].inspect}" unless Ulid.valid?(data[it]) }
      if data['in_reply_to'] && !Ulid.valid?(data['in_reply_to'])
        raise Error, "bad in_reply_to #{data['in_reply_to'].inspect}"
      end

      %w[from to].each { raise Error, "bad #{it} address #{data[it].inspect}" unless address?(data[it]) }
    end

    def self.check_body(body)
      raise Error, 'the body is not text' unless body.is_a?(String)
      return if body.bytesize <= MAX_BODY_BYTES

      raise Error, "the body is #{body.bytesize} bytes and the limit is #{MAX_BODY_BYTES}"
    end

    def self.address?(value) = value.is_a?(String) && ADDRESS.match?(value)

    def self.time(text)
      return nil if text.nil?
      raise Error, "bad time #{text.inspect}" unless text.is_a?(String)

      Time.iso8601(text)
    rescue ArgumentError => e
      raise Error, "bad time: #{e.message}"
    end
    private_class_method :check_fields, :check_identity, :check_body, :address?, :time

    def request? = kind == 'request'

    def reply? = kind == 'reply'

    def overdue?(now) = request? && !due_at.nil? && now > due_at

    def answers?(request)
      reply? && request.request? && in_reply_to == request.id && thread == request.thread &&
        from == request.to && to == request.from
    end

    def summary(width = 60)
      line = body.each_line.map(&:strip).find { !it.empty? }.to_s
      line = Text.plain(line)
      line.size > width ? "#{line[0, width - 3]}..." : line
    end

    def record
      FIELDS.to_h { [it, public_send(it)] }.merge('created_at' => created_at.utc.iso8601,
                                                  'due_at' => due_at&.utc&.iso8601)
    end

    def to_json(*) = JSON.generate({ 'keryx' => FORMAT_VERSION, **record }, *)
  end
end
