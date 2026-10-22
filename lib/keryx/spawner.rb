# frozen_string_literal: true

require_relative 'bell'
require_relative 'error'

module Keryx
  class Spawner
    POLL_SECONDS = 1
    BLOCKED = 'blocked'
    # herdr returns agent_not_ready when the agent stops at a dialog while it starts.
    NOT_READY = 'agent_not_ready'
    START_TIMEOUT = 'timeout'

    def initialize(herdr:, store:, socket:, clock:, sleeper:, notice:)
      @herdr = herdr
      @store = store
      @socket = socket
      @clock = clock
      @sleeper = sleeper
      @notice = notice
      @noticed = false
      @dialog = false
    end

    def place(from, split:, tab:, cwd:, env:)
      return @herdr.split(@socket, from, direction: split, cwd:, env:) unless tab

      workspace = @herdr.pane(@socket, from).workspace
      found = @herdr.tabs(@socket, workspace).find { it.label == tab }
      return @herdr.create_tab(@socket, workspace, label: tab, cwd:, env:) unless found

      last = @herdr.panes(@socket, workspace).select { it.tab == found.id }.last
      raise Error, "herdr lists no pane in the tab #{tab}" unless last

      @herdr.split(@socket, last.id, direction: split, cwd:, env:)
    end

    def run(name, address, pane, kind:, arguments:, before:, deadline:)
      starting = @herdr.start(@socket, pane, name:, kind:, arguments:, timeout: deadline - @clock.call)
      loop do
        occupant = @store.occupant(name)
        return on_time(occupant, address, pane, deadline) if occupant && started?(occupant, pane, kind)
        raise Error, conflict(address, occupant, pane) if occupant && occupant != before

        watch(address, pane, kind, ready?(starting, pane, kind))
        raise WaitTimeout, late(address, pane) if @clock.call >= deadline

        @sleeper.call(POLL_SECONDS)
      end
    ensure
      starting&.stop
    end

    private

    def ready?(starting, pane, kind)
      outcome = starting.outcome or return false
      return true if outcome.ok || outcome.code == START_TIMEOUT
      unless outcome.code == NOT_READY
        raise Error, "herdr could not start #{kind} in pane #{pane}: " \
                     "#{[outcome.code, outcome.detail].compact.join(': ')}"
      end

      dialog(pane)
      true
    end

    def on_time(occupant, address, pane, deadline)
      return occupant if occupant.joined_at <= deadline

      raise WaitTimeout, "#{address} joined only after the timeout passed; its session runs in pane #{pane}"
    end

    def started?(occupant, pane, kind)
      occupant.harness == kind && occupant.herdr_socket == @socket && occupant.herdr_pane == pane
    end

    def conflict(address, occupant, pane)
      "#{address} was joined by another #{occupant.harness} session, not the one spawn started in pane #{pane}; " \
        "'keryx who' shows it"
    end

    # herdr lists the agent once it detects it, so a pane without one means something only after the start ends.
    def watch(address, pane, kind, ready)
      agent = @herdr.agent(@socket, pane)
      return shown(pane, agent) if agent&.kind == kind
      return unless ready

      raise Error, "no #{kind} session runs in pane #{pane}, and #{address} has not joined; look at the pane"
    end

    def shown(pane, agent)
      @dialog = agent.status == BLOCKED || Bell::DIALOG.match?(@herdr.screen(@socket, pane).to_s)
      dialog(pane) if @dialog
    end

    def dialog(pane)
      @dialog = true
      return if @noticed

      @noticed = true
      @notice.call("Pane #{pane} shows a dialog, such as a folder trust or permission question. Answer it there; " \
                   'keryx never answers one. The session joins once it is answered.')
    end

    def late(address, pane)
      return "#{address} has not joined yet; look at pane #{pane}" unless @dialog

      "#{address} has not joined yet: pane #{pane} shows a dialog for you to answer, and the session joins by itself " \
        'once it is answered'
    end
  end
end
