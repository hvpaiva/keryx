# frozen_string_literal: true

require 'json'
require_relative 'error'
require_relative 'runner'

module Keryx
  class Herdr
    Agent = Data.define(:pane, :kind, :status)
    Outcome = Data.define(:ok, :code, :detail)
    Pane = Data.define(:id, :tab, :workspace)
    Tab = Data.define(:id, :label)
    SCREEN_LINES = '20'
    START_TIMEOUT_MS = (3001..300_000)
    START_GRACE = 5

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

    def prompt(socket, pane, text) = outcome(run(socket, 'agent', 'prompt', pane, text))

    def pane(socket, id) = pane_of(control(socket, 'pane', 'get', id)['pane'])

    def panes(socket, workspace)
      Array(control(socket, 'pane', 'list', '--workspace', workspace)['panes']).map { pane_of(it) }
    end

    def tabs(socket, workspace)
      Array(control(socket, 'tab', 'list', '--workspace', workspace)['tabs']).map do |tab|
        Tab.new(id: tab['tab_id'], label: tab['label'])
      end
    end

    def split(socket, pane, direction:, cwd:, env: {})
      pane_of(control(socket, 'pane', 'split', pane, '--direction', direction, '--cwd', cwd, *env_options(env),
                      '--no-focus')['pane'])
    end

    def create_tab(socket, workspace, label:, cwd:, env: {})
      pane_of(control(socket, 'tab', 'create', '--workspace', workspace, '--label', label, '--cwd', cwd,
                      *env_options(env), '--no-focus')['root_pane'])
    end

    def start(socket, pane, name:, kind:, arguments:, timeout:)
      milliseconds = (timeout * 1000).round.clamp(START_TIMEOUT_MS)
      outcome(run(socket, 'agent', 'start', name, '--kind', kind, '--pane', pane, '--timeout', milliseconds.to_s,
                  '--', *arguments, timeout: (milliseconds / 1000.0) + START_GRACE))
    end

    private

    def run(socket, *arguments, timeout: nil)
      @runner.call([@program, *arguments], env: { 'HERDR_SOCKET_PATH' => socket }, **{ timeout: }.compact)
    end

    def json(result)
      JSON.parse(result.success ? result.out : result.err)
    rescue JSON::ParserError
      nil
    end

    def outcome(result)
      return Outcome.new(ok: true, code: nil, detail: nil) if result.success

      error = error_of(json(result))
      Outcome.new(ok: false, code: error['code'], detail: error['message'] || result.err.strip)
    end

    def control(socket, *arguments)
      result = run(socket, *arguments)
      data = json(result)
      return data['result'] if result.success && data.is_a?(Hash) && data['result'].is_a?(Hash)

      reason = error_of(data)['message'] || result.err.strip.lines.first&.strip
      raise Error, "herdr #{arguments.first(2).join(' ')} failed: #{reason.to_s.empty? ? 'no answer' : reason}"
    end

    def error_of(data) = data.is_a?(Hash) && data['error'].is_a?(Hash) ? data['error'] : {}

    def pane_of(data)
      raise Error, 'herdr answered without a pane' unless data.is_a?(Hash) && data['pane_id']

      Pane.new(id: data['pane_id'], tab: data['tab_id'], workspace: data['workspace_id'])
    end

    def env_options(env) = env.flat_map { |key, value| ['--env', "#{key}=#{value}"] }
  end
end
