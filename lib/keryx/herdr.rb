# frozen_string_literal: true

require 'json'
require_relative 'runner'

module Keryx
  # The few herdr commands keryx needs. Every call names its server through HERDR_SOCKET_PATH,
  # because the pane being reached may live on a different herdr session than the caller's.
  class Herdr
    Agent = Data.define(:pane, :kind, :status)
    Outcome = Data.define(:ok, :code, :detail)
    # Lines read from the bottom of the pane when checking for a dialog before typing.
    SCREEN_LINES = '20'

    def initialize(runner: Runner.new, program: 'herdr')
      @runner = runner
      @program = program
    end

    # nil when the pane holds no recognized agent or herdr cannot be reached.
    def agent(socket, pane)
      data = json(run(socket, 'agent', 'get', pane))
      agent = data&.dig('result', 'agent') or return nil
      Agent.new(pane: agent['pane_id'], kind: agent['agent'], status: agent['agent_status'])
    end

    # Every recognized agent on the server, or an empty list when herdr cannot be reached.
    def agents(socket)
      data = json(run(socket, 'agent', 'list'))
      Array(data&.dig('result', 'agents')).map do |agent|
        Agent.new(pane: agent['pane_id'], kind: agent['agent'], status: agent['agent_status'])
      end
    end

    # The plain text herdr uses to recognize the agent: the bottom of the screen.
    def screen(socket, pane)
      result = run(socket, 'agent', 'read', pane, '--source', 'detection', '--lines', SCREEN_LINES)
      result.success ? result.out : nil
    end

    # Types the text into the agent's input and submits it. herdr refuses an agent that shows a
    # recognized approval or question dialog, and reports that as code agent_blocked.
    def prompt(socket, pane, text)
      result = run(socket, 'agent', 'prompt', pane, text)
      return Outcome.new(ok: true, code: nil, detail: nil) if result.success

      error = json(result)&.fetch('error', nil) || {}
      Outcome.new(ok: false, code: error['code'], detail: error['message'] || result.err.strip)
    end

    private

    def run(socket, *arguments)
      @runner.call([@program, *arguments], env: { 'HERDR_SOCKET_PATH' => socket })
    end

    # herdr prints JSON on stdout on success and on stderr on failure.
    def json(result)
      JSON.parse(result.success ? result.out : result.err)
    rescue JSON::ParserError
      nil
    end
  end
end
