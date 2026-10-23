# frozen_string_literal: true

require_relative 'bell'
require_relative 'error'
require_relative 'spawned'

module Keryx
  class Spawner
    POLL_SECONDS = 1
    BLOCKED = 'blocked'
    # herdr returns agent_not_ready when the agent stops at a dialog while it starts.
    NOT_READY = 'agent_not_ready'
    START_TIMEOUT = 'timeout'
    # The classic terminal, which keeps Cursor's dialogs and footer on one line and the screen lines the bell reads.
    MIN_COLUMNS = 80
    MIN_ROWS = 24
    DOWN = 'down'
    PLACEMENT = 'spawn runs in a herdr pane. Of the panes in this tab, or with --tab in every tab labelled LABEL, it ' \
                'splits the one that leaves the new pane the most room along --split, provided the new pane gets at ' \
                "least #{MIN_COLUMNS} columns and #{MIN_ROWS} rows, which keep a harness's dialogs and footer on " \
                'whole lines; when no pane has that room, it opens a new tab labelled LABEL, or NAME without --tab. ' \
                'When herdr gives no layout, it splits this pane, or the last pane of the tab LABEL, without ' \
                'checking its size. Splitting is the only change spawn makes to a pane it did not create, and it ' \
                'labels the new pane NAME.'.freeze

    def initialize(herdr:, store:, socket:, clock:, sleeper:, notice:)
      @herdr = herdr
      @store = store
      @socket = socket
      @clock = clock
      @sleeper = sleeper
      @notice = notice
      @noticed = false
      @dialog = false
      @seen = false
    end

    def place(from, label:, **placement)
      placed(from, label, **placement).tap { name(it.id, label) }
    end

    def run(name, address, pane, kind:, arguments:, before:, deadline:)
      starting = @herdr.start(@socket, pane, name:, kind:, arguments:, timeout: deadline - @clock.call)
      loop do
        occupant = arrived(name, before)
        return on_time(occupant, address, pane, deadline) if occupant && started?(occupant, pane, kind)
        raise Error, conflict(address, occupant, pane) if occupant

        watch(address, pane, kind, ready?(starting, pane, kind))
        raise WaitTimeout, late(address, pane) if @clock.call >= deadline

        @sleeper.call(POLL_SECONDS)
      end
    ensure
      starting&.stop
    end

    # Recorded before the harness starts, for the join to apply whenever it comes, and removed by the first join of the
    # address, so it goes to the session spawn starts in this pane or to none. It takes no lock, which would hold spawn
    # past its timeout: only a join spawn reports as a conflict can come between the write and the session's join.
    def direct(name, pane, kind, director)
      @store.record_spawned(name, Spawned.new(director:, harness: kind, herdr_socket: @socket, herdr_pane: pane))
    rescue Error, SystemCallError => e
      @notice.call("spawn could not record #{director} as the director of #{name}: #{e.message}.")
    end

    private

    def placed(from, label, split:, tab:, cwd:, env:)
      return fitted([from], label, split:, cwd:, env:) { @herdr.pane(@socket, from).workspace } unless tab

      workspace = @herdr.pane(@socket, from).workspace
      tabs = @herdr.tabs(@socket, workspace).select { it.label == tab }
      return @herdr.create_tab(@socket, workspace, label: tab, cwd:, env:) if tabs.empty?

      fitted(last_panes(workspace, tabs, tab), tab, split:, cwd:, env:) { workspace }
    end

    def last_panes(workspace, tabs, label)
      panes = @herdr.panes(@socket, workspace)
      last = tabs.filter_map { |tab| panes.select { it.tab == tab.id }.last&.id }
      raise Error, "herdr lists no pane in the tab #{label}" if last.empty?

      last
    end

    # Splits the pane of these panes' tabs that leaves the new one the most room, or else opens a tab.
    def fitted(through, label, split:, cwd:, env:)
      rects = layouts(through) or return @herdr.split(@socket, through.first, direction: split, cwd:, env:)
      best = roomiest(rects, split)
      return @herdr.split(@socket, best.pane, direction: split, cwd:, env:) if best

      @herdr.create_tab(@socket, yield, label:, cwd:, env:)
    end

    def layouts(through)
      through.flat_map do |pane|
        @herdr.layout(@socket, pane)
      rescue Error => e
        @notice.call("spawn could not read the layout of pane #{pane}: #{e.message}; it splits pane #{through.first} " \
                     'without checking its size.')
        return nil
      end
    end

    def roomiest(rects, split)
      rooms = rects.to_h { [it, room(it, split)] }
      rooms.select { |_, (columns, rows)| columns >= MIN_COLUMNS && rows >= MIN_ROWS }
           .max_by { |_, (columns, rows)| split == DOWN ? rows : columns }&.first
    end

    # herdr gives the new pane the smaller half: the floor of half the width, or of the height when it splits down.
    def room(rect, split) = split == DOWN ? [rect.width, rect.height / 2] : [rect.width / 2, rect.height]

    def name(pane, label)
      @herdr.rename(@socket, pane, label)
    rescue Error => e
      @notice.call("Pane #{pane} has no label: #{e.message}.")
    end

    # A gone session's record can name the same harness, socket and pane, so only a changed one is a join.
    def arrived(name, before) = @store.occupant(name).then { it unless it == before }

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

    # herdr lists the agent once it detects it, so a pane without one counts once the start ended or the agent was seen.
    def watch(address, pane, kind, ready)
      agent = @herdr.agent(@socket, pane)
      return shown(pane, agent) if agent&.kind == kind
      return unless ready || @seen

      raise Error, "no #{kind} session runs in pane #{pane}, and #{address} has not joined; look at the pane"
    end

    def shown(pane, agent)
      @seen = true
      @dialog = agent.status == BLOCKED ? :dialog : Bell.obstacle(@herdr.screen(@socket, pane))
      dialog(pane, @dialog) if @dialog
    end

    def dialog(pane, obstacle = :dialog)
      @dialog = obstacle
      return if @noticed

      @noticed = true
      @notice.call("Pane #{pane} #{shows(obstacle)}, such as a folder trust or permission question. " \
                   "#{obstacle == :cramped ? 'Look at it' : 'Answer it'} there; keryx never answers one. The session " \
                   "joins once #{obstacle == :cramped ? 'any dialog' : 'it'} is answered.")
    end

    def late(address, pane)
      return "#{address} has not joined yet; look at pane #{pane}" unless @dialog
      if @dialog == :cramped
        return "#{address} has not joined yet: pane #{pane} #{shows(:cramped)}; look at it, and the session joins by " \
               'itself once any dialog is answered'
      end

      "#{address} has not joined yet: pane #{pane} shows a dialog for you to answer, and the session joins by itself " \
        'once it is answered'
    end

    def shows(obstacle) = obstacle == :cramped ? 'is too narrow to tell whether it shows a dialog' : 'shows a dialog'
  end
end
