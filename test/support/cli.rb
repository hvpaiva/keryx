# frozen_string_literal: true

require 'stringio'

# Runs keryx in process against a temporary store, with a clock, sockets, herdr and a process
# table the test controls.
module CLIHelpers
  Run = Data.define(:status, :out, :err)

  class Clock
    attr_reader :now

    def initialize(now)
      @now = now
    end

    def call = @now

    def advance(seconds)
      @now += seconds
    end
  end

  # Records what a Claude Code peer socket would receive; paths listed in `gone` refuse.
  class FakeClaudeSockets
    attr_reader :posts, :gone

    def initialize
      @posts = []
      @gone = []
    end

    def post(path, text)
      raise Errno::ENOENT, path if @gone.include?(path)

      @posts << [path, text]
    end
  end

  # Answers kill(0, pid) for the pids the test calls alive.
  class FakeProcesses
    def initialize(alive)
      @alive = alive
    end

    def kill(_signal, pid)
      raise Errno::ESRCH unless @alive.include?(pid)

      1
    end
  end

  def clock = @clock ||= Clock.new(Factory::NOW)

  def sockets = @sockets ||= FakeClaudeSockets.new

  def herdr = @herdr ||= FakeHerdr.new

  def alive = @alive ||= []

  def base_env = { 'KERYX_HOME' => tmp('state'), 'KERYX_HOST' => 'athena', 'USER' => 'person' }

  def claude(pid)
    { 'CLAUDECODE' => '1', 'CLAUDE_PID' => pid.to_s, 'CLAUDE_CODE_SESSION_ID' => "session-#{pid}",
      'CLAUDE_CODE_MESSAGING_SOCKET' => "/tmp/cc-#{pid}.sock" }
  end

  def keryx(*argv, env: {}, input: '')
    out = StringIO.new
    err = StringIO.new
    terminal = Keryx::CLI::Terminal.new(out:, err:, input: StringIO.new(input), env: base_env.merge(env))
    factory = lambda do |globals|
      Keryx::App.new(env: terminal.env, cwd: '/work', as: globals[:as], clock:, herdr:, claude_socket: sockets,
                     sleeper: ->(seconds) { clock.advance(seconds) }, process: FakeProcesses.new(alive))
    end
    Run.new(Keryx.run(argv, terminal:, app_factory: factory), out.string, err.string)
  end

  # Joins `name` as a live Claude Code session with `pid` and returns that session's env.
  def join_claude(name, pid, role: nil)
    alive << pid
    env = claude(pid)
    result = keryx('join', name, *(role ? ['--role', role] : []), env:)
    raise "join failed: #{result.err}" unless result.status.zero?

    env
  end

  def store = Keryx::Store.new(tmp('state'))

  def last_id(env)
    JSON.parse(keryx('inbox', '--all', '-o', 'json', env:).out).last.fetch('id')
  end
end
