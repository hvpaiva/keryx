# frozen_string_literal: true

require 'time'

module Keryx
  # refreshable is not written: a record without a start field predates keeping processes, and a command can add one.
  Occupant = Data.define(:harness, :session_id, :pid, :started, :claude_socket, :herdr_socket, :herdr_pane, :cwd,
                         :joined_at, :transcript, :refreshable) do
    def initialize(transcript: nil, refreshable: false, **) = super
  end

  class Occupant
    FIELDS = %w[harness session_id pid started claude_socket herdr_socket herdr_pane cwd joined_at transcript].freeze
    # spawn compares joined_at with a deadline, and Time.now carries nanoseconds.
    FRACTION_DIGITS = 9

    def self.from_record(data)
      fields = FIELDS.to_h { [it.to_sym, data[it]] }
      new(**fields, joined_at: Time.iso8601(data.fetch('joined_at')),
                    transcript: transcript(data['transcript'], data['session_id']), refreshable: !data.key?('started'))
    end

    # A transcript is kept only while it is named after the session the record holds.
    def self.transcript(path, session_id)
      path if path.is_a?(String) && File.absolute_path?(path) && File.basename(path) == "#{session_id}.jsonl"
    end
    private_class_method :transcript

    def record = FIELDS.to_h { [it, public_send(it)] }.merge('joined_at' => joined_at.utc.iso8601(FRACTION_DIGITS))

    def herdr? = !herdr_socket.to_s.empty? && !herdr_pane.to_s.empty?
  end
end
