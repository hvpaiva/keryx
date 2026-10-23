# frozen_string_literal: true

module PresenceHelpers
  SOCKET = '/h.sock'

  def codex_in(pane, thread) = { 'CODEX_THREAD_ID' => thread, 'HERDR_SOCKET_PATH' => SOCKET, 'HERDR_PANE_ID' => pane }

  def show(pane, kind, status, session = nil)
    herdr.put(SOCKET, pane, Keryx::Herdr::Agent.new(pane:, kind:, status:, session:))
  end

  # The harness runs as the foreground group of its pane, and keryx runs under it.
  def runs_in(pane, pid)
    herdr.foregrounds[[SOCKET, pane]] = pid
    lineage.replace([pid + 1, pid])
    alive << pid
  end

  # Codex hands its thread to the commands it runs, this one and the shell under it, and keeps herdr's variables.
  def codex_by_hand(pane, pid, secret: 's3cret')
    runs_in(pane, pid)
    carry_thread('thread-1', Process.pid, pid + 1)
    processes.environments[pid] = { 'HERDR_SOCKET_PATH' => SOCKET, 'HERDR_PANE_ID' => pane, 'TOKEN' => secret }
    show(pane, 'codex', 'idle')
    { 'CODEX_THREAD_ID' => 'thread-1' }
  end

  def carry_thread(thread, *pids) = pids.each { processes.environments[it] = { 'CODEX_THREAD_ID' => thread } }

  def session(name)
    addresses = JSON.parse(keryx('who', '--all', '-o', 'json').out)['addresses']
    addresses.find { it['address'] == "#{name}@athena" }['session']
  end

  # A record written before keryx kept processes has no start field at all.
  def bind_impl(older: false, **fields)
    store.create_address('impl')
    occupant = build_occupant(harness: 'codex', session_id: 'thread-1', herdr_socket: SOCKET, herdr_pane: 'w1:p3',
                              **fields)
    store.bind('impl', occupant)
    record = occupant.record.then { older ? it.except('started') : it }
    File.write(tmp('state', 'addresses', 'impl', 'occupant.json'), JSON.generate(record))
    occupant
  end
end
