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

    def start(pane, name:, kind:, arguments:, deadline:)
      outcome = @herdr.start(@socket, pane, name:, kind:, arguments:, timeout: deadline - @clock.call)
      return if outcome.ok || outcome.code == START_TIMEOUT
      return dialog(pane) if outcome.code == NOT_READY

      raise Error, "herdr could not start #{kind} in pane #{pane}: #{[outcome.code, outcome.detail].compact.join(': ')}"
    end

    def await_join(name, address, pane, kind:, before:, deadline:)
      loop do
        occupant = @store.occupant(name)
        return occupant if occupant && occupant.joined_at != before&.joined_at

        watch(address, pane, kind)
        raise WaitTimeout, late(address, pane) if @clock.call >= deadline

        @sleeper.call(POLL_SECONDS)
      end
    end

    private

    def watch(address, pane, kind)
      agent = @herdr.agent(@socket, pane)
      unless agent
        raise Error, "no #{kind} session runs in pane #{pane}, and #{address} has not joined; look at the pane"
      end

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
