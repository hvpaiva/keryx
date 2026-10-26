# frozen_string_literal: true

require_relative 'bell'
require_relative 'dialog'
require_relative 'error'
require_relative 'spawned'
require_relative 'store'
require_relative 'text'

module Keryx
  class Spawner
    POLL_SECONDS = 1
    AGENT_NAME_SIZE = 32
    BLOCKED = 'blocked'
    # herdr returns agent_not_ready when the agent stops at a dialog while it starts.
    NOT_READY = 'agent_not_ready'
    START_TIMEOUT = 'timeout'
    # The classic terminal, which keeps Cursor's dialogs and footer on one line and the screen lines the bell reads.
    MIN_COLUMNS = 80
    MIN_ROWS = 24
    # herdr's layout gives a pane's outer rectangle, and its default chrome takes a border on each side and a scrollbar
    # column from a split pane's terminal, and a border above and below; herdr 0.9.5 reports no terminal size.
    CHROME_COLUMNS = 3
    CHROME_ROWS = 2
    DOWN = 'down'

    # vacant(name, advice) raises the error Spawn's claim raises when a session holds the address.
    def initialize(herdr:, store:, socket:, clock:, sleeper:, deadline:, notice:, post:, vacant:)
      @herdr = herdr
      @store = store
      @socket = socket
      @clock = clock
      @sleeper = sleeper
      @deadline = deadline
      @notice = notice
      @post = post
      @vacant = vacant
      @seen = false
    end

    def place(from, label:, address:, kind:, **placement)
      opening = opening(from, label, **placement)
      due("the timeout passed before spawn opened a pane; it started no session for #{address}")
      opening.call.tap do |pane|
        due(opened(pane.id, kind))
        name(pane.id, label)
        # herdr labels a new workspace's one tab with its number, so it gets the label a new tab would.
        title(pane.tab, placement[:tab] || label) if @founded
      end
    end

    # herdr's agent names hold no dot and up to 32 characters, so MEMBER.TEAM is MEMBER_TEAM there, cut to fit.
    def self.agent_name(name) = name.tr('.', '_')[0, AGENT_NAME_SIZE]

    # herdr names agents apart from keryx, so a session that left its address keeps its herdr name, in its own pane.
    def claim_name(name, own)
      name = Spawner.agent_name(name)
      agent = @herdr.agent(@socket, name) or return
      return @kept = agent.pane if agent.pane == own

      pane = Text.plain(agent.pane)
      raise Error, "herdr already runs an agent named #{name}, in pane #{pane}; choose another name, or free it with " \
                   "'herdr agent rename #{pane} NEWNAME'"
    end

    def run(name, address, pane, kind:, arguments:, before:, director:, prompt:)
      starting = start(name, address, pane, kind, arguments:, director:)
      @dialog = Dialog.new(herdr: @herdr, socket: @socket, pane:, address:, director:, prompt:, notice: @notice,
                           post: @post)
      loop do
        occupant = arrived(name, before)
        return on_time(occupant, address, pane) if occupant && started?(occupant, pane, kind)
        raise Error, conflict(address, occupant, pane) if occupant

        refuse_retired(name, address, orphaned(pane, kind))
        watch(address, pane, kind, ready?(starting, pane, kind))
        raise WaitTimeout, @dialog.late if @clock.call >= @deadline

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

    # No step that changes something starts after the deadline, and none is cut short at it, since a split cut short
    # could leave a pane whose id spawn never learns.
    def due(late)
      raise WaitTimeout, late if @clock.call >= @deadline
    end

    def opened(pane, kind)
      "the timeout passed after spawn opened pane #{pane}, and it started no #{kind} session there; #{shell(pane)}"
    end

    def shell(pane) = "the pane holds only a shell, which 'herdr pane close #{pane}' closes"

    # spawn checked the address and the herdr name before it opened the pane, and a session can change either meanwhile,
    # as retire can the address.
    def start(name, address, pane, kind, arguments:, director:)
      late = opened(pane, kind)
      due(late)
      direct(name, pane, kind, director) if director
      due(late)
      kept = @kept && keeps?(name)
      stopped = "spawn started no #{kind} session in pane #{pane}; #{shell(pane)}"
      held(late, stopped) do
        refuse_retired(name, address, "it was retired after spawn checked the address, and #{stopped}")
        @vacant.call(name, "it joined after spawn checked the address, and #{stopped}")
        free_name(name, late) if kept
      end
      due(late)
      @herdr.start(@socket, pane, name: Spawner.agent_name(name), kind:, arguments:, timeout: @deadline - @clock.call)
    end

    # The lookup can take long, so it runs before the hold, and the address check and the timeout's come after it. keryx
    # holds no herdr name, and herdr clears whatever name the pane holds when the rename runs, so the pane can still
    # change names between the lookup and the clear.
    def keeps?(name) = herdr_name(name) { @herdr.agent(@socket, Spawner.agent_name(name))&.pane == @kept }

    # join takes this lock too, so a join lands before the address check, which stops spawn, or after the clear, which
    # then freed the name of an address no session held. retire takes it too, so a retire before the check stops spawn.
    # spawn waits for it as a join does, but not past its timeout.
    def held(late, stopped, &)
      within = (@deadline - @clock.call).clamp(0, Store::LOCK_SECONDS)
      @store.with_occupants_lock(within:, &)
    rescue Store::Busy => e
      raise WaitTimeout, late if within < Store::LOCK_SECONDS

      raise Store::Busy, "#{e.message}; #{stopped}"
    end

    # Without a request in its mailbox, a retire can still land after the last check, and the session spawn started then
    # has its join refused, so spawn would wait for it until the timeout.
    def orphaned(pane, kind)
      "it was retired after spawn started the #{kind} session in pane #{pane}, which runs with no address; " \
        "'herdr pane close #{pane}' closes it"
    end

    def refuse_retired(name, address, advice)
      raise Error, "#{address} is retired; #{advice}" if @store.retired?(name)
    end

    def free_name(name, late)
      due(late)
      herdr_name(name) { @herdr.clear_name(@socket, @kept) }
    end

    def herdr_name(name)
      yield
    rescue Error => e
      raise Error, "spawn could not free the herdr name #{Spawner.agent_name(name)} in pane #{Text.plain(@kept)}: " \
                   "#{e.message}"
    end

    # The step that opens the new pane, once the reads that choose it are done.
    def opening(from, label, split:, tab:, cwd:, env:, workspace: nil)
      return fitted([from], label, split:, cwd:, env:) { @herdr.pane(@socket, from).workspace } unless tab || workspace

      own = @herdr.pane(@socket, from).workspace
      target = workspace ? labelled(workspace, own) : own
      @founded = target.nil?
      return -> { @herdr.create_workspace(@socket, label: workspace, cwd:, env:) } if @founded
      return tabbed(target, tab, split:, cwd:, env:) if tab
      return fitted([from], label, split:, cwd:, env:) { own } if target == own

      -> { @herdr.create_tab(@socket, target, label:, cwd:, env:) }
    end

    def tabbed(workspace, tab, split:, cwd:, env:)
      tabs = @herdr.tabs(@socket, workspace).select { it.label == tab }
      return -> { @herdr.create_tab(@socket, workspace, label: tab, cwd:, env:) } if tabs.empty?

      fitted(last_panes(workspace, tabs, tab), tab, split:, cwd:, env:) { workspace }
    end

    # herdr finds a workspace only by id or number, so spawn finds it by label: this pane's when it has the label, else
    # the first herdr lists with it.
    def labelled(label, own)
      @herdr.workspaces(@socket).filter_map { it.id if it.label == label }.then { it.include?(own) ? own : it.first }
    end

    def last_panes(workspace, tabs, label)
      panes = @herdr.panes(@socket, workspace)
      last = tabs.filter_map { |tab| panes.select { it.tab == tab.id }.last&.id }
      raise Error, "herdr lists no pane in the tab #{label}" if last.empty?

      last
    end

    # A split of the pane of these panes' tabs that leaves the new one the most room, or else a new tab.
    def fitted(through, label, split:, cwd:, env:)
      best = layouts(through)&.then { roomiest(it, split) }
      return -> { @herdr.split(@socket, best.pane, direction: split, cwd:, env:) } if best

      workspace = yield
      -> { @herdr.create_tab(@socket, workspace, label:, cwd:, env:) }
    end

    def layouts(through)
      through.flat_map do |pane|
        @herdr.layout(@socket, pane)
      rescue Error => e
        @notice.call("spawn could not read the layout of pane #{pane}: #{e.message}; it opens a new tab rather than " \
                     'split a pane it could not measure.')
        return nil
      end
    end

    def roomiest(rects, split)
      rooms = rects.to_h { [it, room(it, split)] }
      rooms.select { |_, (columns, rows)| columns >= MIN_COLUMNS && rows >= MIN_ROWS }
           .max_by { |_, (columns, rows)| split == DOWN ? rows : columns }&.first
    end

    # herdr gives the new pane the smaller half: the floor of half the width, or of the height when it splits down.
    def room(rect, split)
      columns, rows = split == DOWN ? [rect.width, rect.height / 2] : [rect.width / 2, rect.height]
      [columns - CHROME_COLUMNS, rows - CHROME_ROWS]
    end

    def name(pane, label)
      @herdr.rename(@socket, pane, label)
    rescue Error => e
      @notice.call("Pane #{pane} has no label: #{e.message}.")
    end

    def title(tab, label)
      @herdr.rename_tab(@socket, tab, label)
    rescue Error => e
      @notice.call("Tab #{tab} keeps the label herdr gave it, not #{label}: #{e.message}.")
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

      @dialog.signal(:dialog)
      true
    end

    def on_time(occupant, address, pane)
      return occupant if occupant.joined_at <= @deadline

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
      @dialog.signal(agent.status == BLOCKED ? :dialog : Bell.obstacle(@herdr.screen(@socket, pane)))
    end
  end
end
