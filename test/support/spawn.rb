# frozen_string_literal: true

module SpawnHelpers
  SOCKET = '/h.sock'
  CALLER = { 'HERDR_SOCKET_PATH' => SOCKET, 'HERDR_PANE_ID' => 'w1:p1' }.freeze
  NOT_READY = Keryx::Herdr::Outcome.new(ok: false, code: 'agent_not_ready', detail: 'agent is blocked during startup')

  def setup
    super
    @herdr = FakeHerdr.new(panes: [Keryx::Herdr::Pane.new(id: 'w1:p1', tab: 'w1:t1', workspace: 'w1')],
                           tabs: { 'w1' => [Keryx::Herdr::Tab.new(id: 'w1:t1', label: 'main')] })
  end

  def spawn(*argv, env: {}, input: '') = keryx('spawn', *argv, env: CALLER.merge(env), input:)

  def session_env = { 'KERYX_HOME' => tmp('state'), 'KERYX_HOST' => 'athena' }

  def agent(pane, kind, status) = Keryx::Herdr::Agent.new(pane:, kind:, status:)

  def in_pane(socket, pane) = { 'HERDR_SOCKET_PATH' => socket, 'HERDR_PANE_ID' => pane }

  def session_joins(pid: 500)
    herdr.on_start = lambda do |socket, pane, name, kind|
      herdr.put(socket, pane, agent(pane, kind, 'working'))
      alive << pid
      session = kind == 'codex' ? { 'CODEX_THREAD_ID' => "thread-#{pid}" } : claude(pid)
      keryx('join', name, env: session.merge(in_pane(socket, pane)))
    end
  end

  def session_runs(screen: nil)
    herdr.on_start = lambda do |socket, pane, _name, kind|
      herdr.put(socket, pane, agent(pane, kind, 'idle'))
      herdr.show(socket, pane, screen) if screen
    end
  end
end
