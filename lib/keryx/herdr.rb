# frozen_string_literal: true

require 'json'
require_relative 'runner'

module Keryx
  class Herdr
    Agent = Data.define(:pane, :kind, :status)
    Outcome = Data.define(:ok, :code, :detail)
    SCREEN_LINES = '20'

    def initialize(runner: Runner.new, program: 'herdr')
      @runner = runner
      @program = program
    end

    def agent(socket, pane)
      data = json(run(socket, 'agent', 'get', pane))
      agent = data&.dig('result', 'agent') or return nil
      Agent.new(pane: agent['pane_id'], kind: agent['agent'], status: agent['agent_status'])
    end

    def agents(socket)
      data = json(run(socket, 'agent', 'list'))
      Array(data&.dig('result', 'agents')).map do |agent|
        Agent.new(pane: agent['pane_id'], kind: agent['agent'], status: agent['agent_status'])
      end
    end

    def screen(socket, pane)
      result = run(socket, 'agent', 'read', pane, '--source', 'detection', '--lines', SCREEN_LINES)
      result.success ? result.out : nil
    end

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

    def json(result)
      JSON.parse(result.success ? result.out : result.err)
    rescue JSON::ParserError
      nil
    end
  end
end
