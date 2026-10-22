# frozen_string_literal: true

require 'time'

module Keryx
  Occupant = Data.define(:harness, :session_id, :pid, :claude_socket, :herdr_socket, :herdr_pane, :cwd, :joined_at)

  # The session that holds an address. `claude_socket` is the Claude Code peer socket the
  # session listens on; `herdr_socket` and `herdr_pane` locate its pane, whatever the harness.
  # `pid` is the harness process when it is known.
  class Occupant
    FIELDS = %w[harness session_id pid claude_socket herdr_socket herdr_pane cwd joined_at].freeze

    def self.from_record(data)
      new(**FIELDS.to_h { [it.to_sym, data[it]] }, joined_at: Time.iso8601(data.fetch('joined_at')))
    end

    def record = FIELDS.to_h { [it, public_send(it)] }.merge('joined_at' => joined_at.utc.iso8601)

    def herdr? = !herdr_socket.to_s.empty? && !herdr_pane.to_s.empty?

    # :live or :gone when the harness process is known, :unknown when only herdr can tell.
    def presence(process: Process)
      return :unknown unless pid

      process.kill(0, pid)
      :live
    rescue Errno::ESRCH
      :gone
    rescue Errno::EPERM
      :live
    end
  end
end
