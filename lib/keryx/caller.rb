# frozen_string_literal: true

require_relative 'occupant'

module Keryx
  Caller = Data.define(:harness, :session_id, :pid, :claude_socket, :herdr_socket, :herdr_pane, :cwd)

  class Caller
    def self.from_env(env, cwd:, herdr:)
      socket = value(env, 'HERDR_SOCKET_PATH')
      pane = value(env, 'HERDR_PANE_ID')
      fields = harness_fields(env) || pane_fields(herdr, socket, pane)
      new(harness: fields[:harness], session_id: fields[:session_id], pid: fields[:pid],
          claude_socket: fields[:claude_socket], herdr_socket: socket, herdr_pane: pane, cwd:)
    end

    def self.harness_fields(env)
      if value(env, 'CURSOR_CONVERSATION_ID')
        { harness: 'cursor', session_id: value(env, 'CURSOR_CONVERSATION_ID') }
      elsif value(env, 'CODEX_THREAD_ID')
        { harness: 'codex', session_id: value(env, 'CODEX_THREAD_ID') }
      elsif env['CLAUDECODE'] == '1'
        { harness: 'claude', session_id: value(env, 'CLAUDE_CODE_SESSION_ID'),
          pid: Integer(env['CLAUDE_PID'].to_s, 10, exception: false),
          claude_socket: value(env, 'CLAUDE_CODE_MESSAGING_SOCKET') }
      end
    end

    # A harness that sets no variable of its own takes its name and its session id from what herdr reports.
    def self.pane_fields(herdr, socket, pane)
      agent = herdr.agent(socket, pane) if socket && pane
      { harness: agent&.kind, session_id: agent&.session }
    end

    def self.value(env, name)
      text = env[name].to_s
      text.empty? ? nil : text
    end
    private_class_method :harness_fields, :pane_fields, :value

    def agent? = !harness.nil?

    def holds?(occupant) = same_session?(occupant) || same_pane?(occupant)

    def same_session?(occupant)
      (!pid.nil? && occupant.pid == pid) || (!session_id.nil? && occupant.session_id == session_id)
    end

    def same_pane?(occupant)
      !herdr_pane.nil? && occupant.harness == harness && occupant.herdr_socket == herdr_socket &&
        occupant.herdr_pane == herdr_pane
    end

    def occupant(now)
      Occupant.new(harness:, session_id:, pid:, started: nil, claude_socket:, herdr_socket:, herdr_pane:, cwd:,
                   joined_at: now)
    end
  end
end
