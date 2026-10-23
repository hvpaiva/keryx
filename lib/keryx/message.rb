# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'address'
require_relative 'context'
require_relative 'error'
require_relative 'text'
require_relative 'ulid'

module Keryx
  Message = Data.define(:id, :kind, :from, :to, :thread, :in_reply_to, :created_at, :due_at, :body, :context) do
    def initialize(context: nil, **) = super
  end

  class Message
    KINDS = %w[message request reply withdrawal].freeze
    # Format 2 spells team and session addresses. A message between two addresses from before team names is still
    # written as format 1, so a machine with an older keryx takes what finishes the threads it has.
    FORMAT_VERSION = 2
    FLAT_FORMAT = 1
    FORMATS = [FLAT_FORMAT, FORMAT_VERSION].freeze
    MAX_BODY_BYTES = 64 * 1024
    FIELDS = %w[id kind from to thread in_reply_to created_at due_at body].freeze
    # The body of a withdrawal whose sender gave no reason.
    WITHDRAWN = 'Request %<id>s is withdrawn and needs no reply.'

    def self.from_json(text)
      data = JSON.parse(text)
      raise Error, 'not a keryx message' unless data.is_a?(Hash) && FORMATS.include?(data['keryx'])

      build(data).tap { it.check_format(data['keryx']) }
    rescue JSON::ParserError => e
      raise Error, "not valid JSON (#{e.message.lines.first.strip})"
    end

    def self.build(data)
      check_fields(data)
      new(id: data['id'], kind: data['kind'], from: data['from'], to: data['to'], thread: data['thread'],
          in_reply_to: data['in_reply_to'], created_at: time(data['created_at']), due_at: time(data['due_at']),
          body: data['body'], context: Context.from_record(data['context']))
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

    def self.address?(value) = value.is_a?(String) && Address.valid?(value)

    def self.time(text)
      return nil if text.nil?
      raise Error, "bad time #{text.inspect}" unless text.is_a?(String)

      Time.iso8601(text)
    rescue ArgumentError => e
      raise Error, "bad time: #{e.message}"
    end
    private_class_method :check_fields, :check_identity, :check_body, :address?, :time

    def format = [from, to].all? { Address.parse(it).flat? } ? FLAT_FORMAT : FORMAT_VERSION

    def check_format(version)
      return if version == FORMAT_VERSION || format == FLAT_FORMAT

      raise Error, "format #{version} carries only addresses without a team"
    end

    def request? = kind == 'request'

    def reply? = kind == 'reply'

    def withdrawal? = kind == 'withdrawal'

    def overdue?(now) = request? && !due_at.nil? && now > due_at

    def answers?(request)
      reply? && request.request? && in_reply_to == request.id && thread == request.thread &&
        from == request.to && to == request.from
    end

    # A message, not a reply, from the request's recipient in its thread: the request is taken and stays open.
    def takes?(request)
      kind == 'message' && request.request? && in_reply_to == request.id && thread == request.thread &&
        from == request.to && to == request.from
    end

    def withdraws?(request)
      withdrawal? && request.request? && in_reply_to == request.id && thread == request.thread &&
        from == request.from && to == request.to
    end

    def summary(width = 60)
      line = body.each_line.map(&:strip).find { !it.empty? }.to_s
      line = Text.plain(line)
      line.size > width ? "#{line[0, width - 3]}..." : line
    end

    def record
      FIELDS.to_h { [it, public_send(it)] }
            .merge('created_at' => created_at.utc.iso8601, 'due_at' => due_at&.utc&.iso8601)
            .merge(context ? { 'context' => context.record } : {})
    end

    def to_json(*) = JSON.generate({ 'keryx' => format, **record }, *)
  end
end
