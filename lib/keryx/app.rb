# frozen_string_literal: true

require 'rbconfig'
require_relative 'address'
require_relative 'bell'
require_relative 'caller'
require_relative 'config'
require_relative 'courier'
require_relative 'forwarder'
require_relative 'herdr'
require_relative 'identity'
require_relative 'lookout'
require_relative 'meter'
require_relative 'paths'
require_relative 'postman'
require_relative 'processes'
require_relative 'receiver'
require_relative 'remote'
require_relative 'resolver'
require_relative 'roster'
require_relative 'runner'
require_relative 'store'

module Keryx
  class App
    HERDR_VARIABLES = %w[HERDR_SOCKET_PATH HERDR_PANE_ID].freeze
    SESSION_VARIABLES = { 'codex' => 'CODEX_THREAD_ID', 'cursor' => 'CURSOR_CONVERSATION_ID' }.freeze

    attr_reader :env, :cwd, :as, :clock, :sleeper, :processes, :host_os, :monotonic

    def initialize(env:, cwd: Dir.pwd, as: nil, clock: -> { Time.now.utc }, herdr: nil,
                   claude_socket: Bell::ClaudeSocket.new, codex: Bell::CodexQueue.new, remote: nil,
                   sleeper: ->(seconds) { sleep(seconds) }, processes: Processes.new,
                   host_os: RbConfig::CONFIG['host_os'],
                   monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @env = env
      @cwd = cwd
      @host_os = host_os
      @as = as || present(env['KERYX_AS'])
      @clock = clock
      @herdr = herdr
      @claude_socket = claude_socket
      @codex = codex
      @remote = remote
      @sleeper = sleeper
      @processes = processes
      @monotonic = monotonic
      @reported = []
    end

    def now = clock.call

    def store = @store ||= Store.new(Paths.new(env).root, clock:, sleeper:)

    def config = @config ||= Config.new(Paths.new(env).config)

    def host = @host ||= Address.local_host(env, config:)

    def herdr = @herdr ||= Herdr.new(runner: Runner.new)

    def caller = @caller ||= Caller.from_env(env, cwd:, herdr:)

    def identity = @identity ||= Identity.new(store:, caller:, env:, host:)

    def lookout = @lookout ||= Lookout.new(herdr:, processes:)

    def bell = @bell ||= Bell.new(store:, herdr:, clock:, claude_socket: @claude_socket, codex: @codex, lookout:)

    def remote = @remote ||= Remote.from_env(env)

    def forwarder = @forwarder ||= Forwarder.new(store:, remote:, clock:)

    def postman
      @postman ||= Postman.new(store:, bell:, forwarder:, host:, clock:, person: identity.human_name,
                               measure: ->(name) { context_of(name) },
                               live: ->(name) { roster.live?(store.reporting { store.occupant(name) }) })
    end

    def receiver = @receiver ||= Receiver.new(store:, bell:, host:, person: identity.human_name)

    def courier
      @courier ||= Courier.new(store:, forwarder:, bell:, postman:, host:, clock:,
                               roster: -> { Roster.new(store:, herdr:, lookout:) },
                               meter: -> { Meter.new(env:, herdr:, lookout:) })
    end

    def roster = @roster ||= Roster.new(store:, herdr:, lookout:)

    def meter = @meter ||= Meter.new(env:, herdr:, lookout:)

    # Only the session that holds the address is measured, and a command that names its address with --as stamps
    # nothing, since the pane or process it shares may have held that address for another session.
    def context_of(name)
      return if @as

      occupant = store.occupant(name)
      meter.read(occupant) if occupant && caller.holds?(occupant)
    end

    def me
      @me ||= identity.current(as: @as).tap { refresh(it) unless @as }
    end

    # The address this command acts as when it has one, without creating the person's address as me would.
    def own_address
      return me if @as

      person = identity.human_name
      identity.held || (person if !caller.agent? && store.address?(person))
    end

    # The occupant this session records, with the harness process it runs in so that the bell can tell it apart.
    def session_occupant(joined_at, previous: nil)
      socket, pane, group = place(previous)
      pid, started = harness_process(previous) { group || pane_group(socket, pane) }
      caller.occupant(joined_at).with(pid:, started:, herdr_socket: socket, herdr_pane: pane)
    end

    def resolver = @resolver ||= Resolver.new(store:, host:)

    # A name typed on the command line, resolved for the address this command acts as. FLAT takes a full address from
    # before team names, which only finishes its threads.
    def address(text, flat: false) = resolver.resolve(text, sender: -> { own_address }, flat:)

    def full(name) = "#{name}@#{host}"

    # Each problem is taken once for the life of the process, and the lists are emptied since the courier never ends.
    def take_problems
      lists = [@config&.problems, @store&.problems].compact
      fresh = lists.flatten.uniq - @reported
      lists.each(&:clear)
      @reported.concat(fresh)
      fresh
    end

    private

    def refresh(name)
      occupant = store.occupant(name) or return
      return unless caller.agent? && (fresh = renewed(occupant)) != occupant

      store.with_occupants_lock(within: 0) { rebind(name, occupant, fresh) }
    rescue Store::Busy
      nil # The record can wait for a later command; the command that called App#me cannot wait for the lock.
    end

    # A join may have moved the session since the first read, so only the occupant read under the lock counts.
    def rebind(name, occupant, fresh)
      current = store.occupant(name)
      store.bind(name, current == occupant ? fresh : renewed(current)) if current && caller.holds?(current)
    end

    def renewed(occupant)
      session_occupant(occupant.joined_at, previous: occupant).with(**occupant.to_h.slice(*Occupant::KEPT))
    end

    def harness_process(previous, &) = (previous&.pid && kept(previous)) || current_process(&)

    # The recorded process stays until an answer shows that another one runs the session; a failed lookup keeps it.
    def kept(previous)
      return if under?(previous.pid) == false

      started = processes.started(previous.pid)
      replaced = started && previous.started && started != previous.started
      [previous.pid, previous.started || started] unless replaced
    end

    def current_process
      pid = caller.pid || yield
      [pid, pid && processes.started(pid)]
    end

    # Claude Code names its process; any other harness runs this command as a descendant, unless ps did not answer.
    def under?(pid)
      return caller.pid == pid if caller.pid

      ancestors = processes.ancestors(Process.pid)
      ancestors.include?(pid) unless ancestors.empty?
    end

    # A harness that does not name its process runs as the foreground group of its herdr pane, an ancestor of this one.
    def pane_group(socket, pane)
      return unless socket && pane

      group = herdr.foreground(socket, pane)
      group if group && processes.ancestors(Process.pid).include?(group)
    end

    # herdr's variables name the pane; without them, the pane an ancestor proves, and else the one recorded before.
    def place(previous)
      return [caller.herdr_socket, caller.herdr_pane] if caller.herdr_socket && caller.herdr_pane

      (inherited_place unless caller.pid) || [previous&.herdr_socket, previous&.herdr_pane]
    end

    # A harness hands its session id only to the commands it runs, so the first process up from this one without it
    # is the harness. Codex keeps herdr's variables itself, and its pane counts only while that harness runs in it.
    def inherited_place
      variable = SESSION_VARIABLES[caller.harness]
      return unless variable && caller.session_id

      harness = [Process.pid, *processes.ancestors(Process.pid)].find do |pid|
        processes.environment(pid, [variable]).to_h[variable] != caller.session_id
      end
      socket, pane = herdr_variables(harness) unless harness == Process.pid
      [socket, pane, harness] if socket && herdr.foreground(socket, pane) == harness
    end

    def herdr_variables(pid)
      found = processes.environment(pid, HERDR_VARIABLES).to_h.values_at(*HERDR_VARIABLES).map { present(it) }
      found if found.all?
    end

    def present(value) = value.to_s.empty? ? nil : value
  end
end
