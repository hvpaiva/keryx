# frozen_string_literal: true

require_relative 'occupant'

module Keryx
  Caller = Data.define(:harness, :session_id, :pid, :claude_socket, :herdr_socket, :herdr_pane, :cwd)

  class Caller
    def self.from_env(env, cwd:, herdr:)
      socket = value(env, 'HERDR_SOCKET_PATH')
      pane = value(env, 'HERDR_PANE_ID')
      claude = env['CLAUDECODE'] == '1' ? claude_fields(env) : nil
      harness = claude ? 'claude' : pane_harness(herdr, socket, pane)
      new(harness:, session_id: claude&.fetch(:session_id), pid: claude&.fetch(:pid),
          claude_socket: claude&.fetch(:claude_socket), herdr_socket: socket, herdr_pane: pane, cwd:)
    end

    def self.claude_fields(env)
      { session_id: value(env, 'CLAUDE_CODE_SESSION_ID'), pid: Integer(env['CLAUDE_PID'].to_s, 10, exception: false),
        claude_socket: value(env, 'CLAUDE_CODE_MESSAGING_SOCKET') }
    end

    def self.pane_harness(herdr, socket, pane) = socket && pane ? herdr.agent(socket, pane)&.kind : nil

    def self.value(env, name)
      text = env[name].to_s
      text.empty? ? nil : text
    end
    private_class_method :claude_fields, :pane_harness, :value

    def agent? = !harness.nil?

    def holds?(occupant) = same_claude?(occupant) || same_pane?(occupant)

    def same_claude?(occupant)
      (!pid.nil? && occupant.pid == pid) || (!session_id.nil? && occupant.session_id == session_id)
    end

    def same_pane?(occupant)
      !herdr_pane.nil? && occupant.harness == harness && occupant.herdr_socket == herdr_socket &&
        occupant.herdr_pane == herdr_pane
    end

    def occupant(now)
      Occupant.new(harness:, session_id:, pid:, claude_socket:, herdr_socket:, herdr_pane:, cwd:, joined_at: now)
    end
  end
end
