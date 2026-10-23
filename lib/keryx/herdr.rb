# frozen_string_literal: true

require 'json'
require_relative 'error'
require_relative 'runner'

module Keryx
  class Herdr
    Agent = Data.define(:pane, :kind, :status, :session) do
      def initialize(pane:, kind:, status:, session: nil) = super
    end
    Outcome = Data.define(:ok, :code, :detail)
    Pane = Data.define(:id, :tab, :workspace)
    Tab = Data.define(:id, :label)
    SCREEN_LINES = '20'
    FOOTER_LINES = 4
    # herdr answered that the pane is gone or runs no agent, which is not the same as not answering.
    NONE = :none
    NOT_FOUND = %w[agent_not_found pane_not_found].freeze
    START_TIMEOUT_MS = (3001..300_000)

    class Starting
      def initialize(job)
        @job = job
      end

      def outcome
        @outcome ||= Herdr.outcome(@job.result) if @job.done?
      end

      def stop = @job.stop
    end

    def self.json(result)
      JSON.parse(result.success ? result.out : result.err)
    rescue JSON::ParserError
      nil
    end

    def self.outcome(result)
      return Outcome.new(ok: true, code: nil, detail: nil) if result.success

      error = error_of(json(result))
      Outcome.new(ok: false, code: error['code'], detail: error['message'] || result.err.strip)
    end

    def self.error_of(data) = data.is_a?(Hash) && data['error'].is_a?(Hash) ? data['error'] : {}

    def initialize(runner: Runner.new, program: 'herdr')
      @runner = runner
      @program = program
    end

    def agent(socket, pane) = look(socket, pane).then { it.is_a?(Agent) ? it : nil }

    def look(socket, pane)
      data = Herdr.json(run(socket, 'agent', 'get', pane))
      agent = data&.dig('result', 'agent')
      return agent_of(agent) if agent.is_a?(Hash)

      NOT_FOUND.include?(Herdr.error_of(data)['code']) ? NONE : nil
    end

    def foreground(socket, pane)
      data = Herdr.json(run(socket, 'pane', 'process-info', '--pane', pane))
      group = data&.dig('result', 'process_info', 'foreground_process_group_id')
      group if group.is_a?(Integer) && group.positive?
    end

    def agents(socket)
      data = Herdr.json(run(socket, 'agent', 'list'))
      Array(data&.dig('result', 'agents')).map { agent_of(it) }
    end

    def screen(socket, pane)
      result = run(socket, 'agent', 'read', pane, '--source', 'detection', '--lines', SCREEN_LINES)
      result.success ? result.out : nil
    end

    def footer(socket, pane)
      result = run(socket, 'pane', 'read', pane, '--source', 'visible', '--lines', FOOTER_LINES.to_s)
      result.success ? result.out : nil
    end

    def prompt(socket, pane, text) = Herdr.outcome(run(socket, 'agent', 'prompt', pane, text))

    def pane(socket, id) = pane_of(control(socket, 'pane', 'get', id)['pane'])

    def panes(socket, workspace)
      Array(control(socket, 'pane', 'list', '--workspace', workspace)['panes']).map { pane_of(it) }
    end

    def tabs(socket, workspace)
      Array(control(socket, 'tab', 'list', '--workspace', workspace)['tabs']).map do |tab|
        Tab.new(id: tab['tab_id'], label: tab['label'])
      end
    end

    def rename(socket, pane, label) = control(socket, 'pane', 'rename', pane, label)

    def split(socket, pane, direction:, cwd:, env: {})
      pane_of(control(socket, 'pane', 'split', pane, '--direction', direction, '--cwd', cwd, *env_options(env),
                      '--no-focus')['pane'])
    end

    def create_tab(socket, workspace, label:, cwd:, env: {})
      pane_of(control(socket, 'tab', 'create', '--workspace', workspace, '--label', label, '--cwd', cwd,
                      *env_options(env), '--no-focus')['root_pane'])
    end

    # herdr agent start waits while the agent works, so it runs in the background until the caller stops it.
    def start(socket, pane, name:, kind:, arguments:, timeout:)
      milliseconds = (timeout * 1000).round.clamp(START_TIMEOUT_MS)
      Starting.new(@runner.start([@program, 'agent', 'start', name, '--kind', kind, '--pane', pane, '--timeout',
                                  milliseconds.to_s, '--', *arguments], env: env(socket)))
    end

    private

    def env(socket) = { 'HERDR_SOCKET_PATH' => socket }

    def run(socket, *arguments) = @runner.call([@program, *arguments], env: env(socket))

    def control(socket, *arguments)
      result = run(socket, *arguments)
      data = Herdr.json(result)
      return data['result'] if result.success && data.is_a?(Hash) && data['result'].is_a?(Hash)

      reason = Herdr.error_of(data)['message'] || result.err.strip.lines.first&.strip
      raise Error, "herdr #{arguments.first(2).join(' ')} failed: #{reason.to_s.empty? ? 'no answer' : reason}"
    end

    def agent_of(data)
      session = data['agent_session']
      Agent.new(pane: data['pane_id'], kind: data['agent'], status: data['agent_status'],
                session: (session['value'] if session.is_a?(Hash) && session['kind'] == 'id'))
    end

    def pane_of(data)
      raise Error, 'herdr answered without a pane' unless data.is_a?(Hash) && data['pane_id']

      Pane.new(id: data['pane_id'], tab: data['tab_id'], workspace: data['workspace_id'])
    end

    def env_options(env) = env.flat_map { |key, value| ['--env', "#{key}=#{value}"] }
  end
end
