# frozen_string_literal: true

require 'time'
require_relative 'address'

module Keryx
  # refreshable is not written: a record without a start field predates keeping processes, and a command can add one.
  Occupant = Data.define(:harness, :session_id, :pid, :started, :claude_socket, :herdr_socket, :herdr_pane, :cwd,
                         :joined_at, :transcript, :ceiling, :director, :refreshable) do
    def initialize(transcript: nil, ceiling: nil, director: nil, refreshable: false, **) = super
  end

  class Occupant
    FIELDS = %w[harness session_id pid started claude_socket herdr_socket herdr_pane cwd joined_at transcript ceiling
                director].freeze
    # What a command that records the session's process again keeps from the record it replaces.
    KEPT = %i[cwd transcript ceiling director].freeze
    # spawn compares joined_at with a deadline, and Time.now carries nanoseconds.
    FRACTION_DIGITS = 9
    TEXT = %w[harness session_id started claude_socket herdr_socket herdr_pane cwd].freeze
    # A pid is a 32-bit signed integer, and Process.kill refuses any number above it.
    PIDS = (1..((2**31) - 1))

    def self.from_record(data)
      raise TypeError, 'the record has a field of the wrong type' unless typed?(data)

      fields = FIELDS.to_h { [it.to_sym, data[it]] }
      new(**fields, joined_at: Time.iso8601(data.fetch('joined_at')),
                    transcript: transcript(data['transcript'], data['session_id']), ceiling: ceiling(data['ceiling']),
                    director: director(data['director']), refreshable: !data.key?('started'))
    end

    def self.typed?(data)
      pid = data['pid']
      (pid.nil? || (pid.is_a?(Integer) && PIDS.cover?(pid))) && TEXT.all? { data[it].nil? || data[it].is_a?(String) }
    end

    def self.ceiling(value) = value.is_a?(Integer) && value.positive? ? value : nil

    def self.director(value) = Address::NAME.match?(value.to_s) ? value : nil

    # A transcript is kept only while it is named after the session the record holds.
    def self.transcript(path, session_id)
      path if path.is_a?(String) && File.absolute_path?(path) && File.basename(path) == "#{session_id}.jsonl"
    end
    private_class_method :typed?, :transcript, :ceiling, :director

    def record = FIELDS.to_h { [it, public_send(it)] }.merge('joined_at' => joined_at.utc.iso8601(FRACTION_DIGITS))

    def herdr? = !herdr_socket.to_s.empty? && !herdr_pane.to_s.empty?
  end
end
