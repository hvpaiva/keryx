# frozen_string_literal: true

module SpawnHelpers
  SOCKET = '/h.sock'
  CALLER = { 'HERDR_SOCKET_PATH' => SOCKET, 'HERDR_PANE_ID' => 'w1:p1' }.freeze
  NOT_READY = Keryx::Herdr::Outcome.new(ok: false, code: 'agent_not_ready', detail: 'agent is blocked during startup')
  # The size herdr gave a full tab in the terminal it was observed in.
  AREA = [205, 48].freeze

  def setup
    super
    workspace(%w[w1:t1 main] => { 'w1:p1' => AREA })
  end

  # Lays out the workspace w1 as tabs of sized panes, such as { %w[w1:t1 main] => { 'w1:p1' => [205, 48] } }.
  def workspace(tabs)
    panes = tabs.flat_map do |(tab, _label), sizes|
      sizes.keys.map { Keryx::Herdr::Pane.new(id: it, tab:, workspace: 'w1') }
    end
    @herdr = FakeHerdr.new(panes:, tabs: { 'w1' => tabs.keys.map { |id, label| Keryx::Herdr::Tab.new(id:, label:) } })
    herdr.sizes = tabs.values.reduce({}) { |all, sizes| all.merge(sizes.transform_values(&:dup)) }
    herdr.area = AREA
  end

  def spawn(*argv, env: {}, input: '') = keryx('spawn', *argv, env: CALLER.merge(env), input:)

  def session_env = { 'KERYX_HOME' => tmp('state'), 'XDG_CONFIG_HOME' => tmp('config'), 'KERYX_HOST' => 'athena' }

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
