# frozen_string_literal: true

require_relative 'address'
require_relative 'bell'
require_relative 'caller'
require_relative 'herdr'
require_relative 'identity'
require_relative 'paths'
require_relative 'postman'
require_relative 'roster'
require_relative 'runner'
require_relative 'store'

module Keryx
  # The services commands share, each built on first use from the environment, so a command that
  # never reads the mailboxes never creates them. Tests pass their own clock, herdr and sockets.
  class App
    attr_reader :env, :cwd, :clock, :sleeper, :process

    def initialize(env:, cwd: Dir.pwd, as: nil, clock: -> { Time.now.utc }, herdr: nil,
                   claude_socket: Bell::ClaudeSocket.new, sleeper: ->(seconds) { sleep(seconds) }, process: Process)
      @env = env
      @cwd = cwd
      @as = as || present(env['KERYX_AS'])
      @clock = clock
      @herdr = herdr
      @claude_socket = claude_socket
      @sleeper = sleeper
      @process = process
    end

    def now = clock.call

    def store = @store ||= Store.new(Paths.new(env).root)

    def host = @host ||= Address.local_host(env)

    def herdr = @herdr ||= Herdr.new(runner: Runner.new)

    def caller = @caller ||= Caller.from_env(env, cwd:, herdr:)

    def identity = @identity ||= Identity.new(store:, caller:, env:)

    def bell = @bell ||= Bell.new(store:, herdr:, clock:, claude_socket: @claude_socket)

    def postman = @postman ||= Postman.new(store:, bell:, host:, clock:)

    def roster = @roster ||= Roster.new(store:, herdr:, process:)

    # The address the caller acts as. A session that restarted in the pane it held keeps the
    # address, and its new process and socket are written down here.
    def me
      @me ||= identity.current(as: @as).tap { refresh(it) unless @as }
    end

    def address(text) = Address.parse(text, local_host: host)

    def full(name) = "#{name}@#{host}"

    def problems = @store ? @store.problems : []

    private

    def refresh(name)
      occupant = store.occupant(name) or return
      current = caller.occupant(occupant.joined_at).with(cwd: occupant.cwd)
      store.bind(name, current) if caller.agent? && current != occupant
    end

    def present(value) = value.to_s.empty? ? nil : value
  end
end
