# frozen_string_literal: true

module BellHelpers
  HERDR_SOCKET = '/run/user/1000/herdr.sock'

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def queue = @queue ||= CLIHelpers::FakeCodexQueue.new

  def processes = @processes ||= CLIHelpers::FakeProcesses.new([])

  def bell(herdr: FakeHerdr.new, claude_socket: Keryx::Bell::ClaudeSocket.new)
    Keryx::Bell.new(store:, herdr:, clock: -> { Factory::NOW }, claude_socket:, codex: queue,
                    lookout: Keryx::Lookout.new(herdr:, processes:))
  end

  def deliver(kind: 'request')
    store.create_address('rev-1')
    build_message(to: 'rev-1@athena', kind:).tap { store.deliver('rev-1', it) }
  end

  def pane_occupant(**overrides)
    build_occupant(harness: 'cursor', session_id: 'conversation-1', herdr_socket: HERDR_SOCKET, herdr_pane: 'w1:p2',
                   **overrides)
  end

  def herdr_with(status, screen: '> ', outcome: Keryx::Herdr::Outcome.new(ok: true, code: nil, detail: nil),
                 session: 'conversation-1', kind: 'cursor')
    agent = Keryx::Herdr::Agent.new(pane: 'w1:p2', kind:, status:, session:)
    screens = { [HERDR_SOCKET, 'w1:p2'] => screen }
    FakeHerdr.new({ [HERDR_SOCKET, 'w1:p2'] => agent }, screens:, prompt_outcome: outcome)
  end
end
