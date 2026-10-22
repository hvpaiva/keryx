# frozen_string_literal: true

require 'stringio'

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

  class FakeProcesses
    def initialize(alive)
      @alive = alive
    end

    def kill(_signal, pid)
      raise Errno::ESRCH unless @alive.include?(pid)

      1
    end
  end

  class FakeCodexQueue
    attr_reader :queued, :gone

    def initialize
      @queued = []
      @gone = []
    end

    def queue(thread, text)
      return Keryx::Runner::Result.new(out: '', err: "no thread #{thread}\n", success: false) if @gone.include?(thread)

      @queued << [thread, text]
      Keryx::Runner::Result.new(out: "Queued message for thread #{thread}.\n", err: '', success: true)
    end
  end

  def clock = @clock ||= Clock.new(Factory::NOW)

  def codex = @codex ||= FakeCodexQueue.new

  def sockets = @sockets ||= FakeClaudeSockets.new

  def herdr = @herdr ||= FakeHerdr.new

  def remote = @remote ||= FakeRemote.new { |host, input| keryx('__receive', env: machine(host), input:).out }

  def machine(host)
    return {} if host == 'athena'

    write_config("host = #{host}\n", home: tmp("#{host}-config"))
    { 'KERYX_HOME' => tmp(host), 'KERYX_HOST' => '', 'XDG_CONFIG_HOME' => tmp("#{host}-config") }
  end

  def write_config(text, home: tmp('config'))
    FileUtils.mkdir_p(File.join(home, 'keryx'))
    File.write(File.join(home, 'keryx', 'config'), text)
  end

  def alive = @alive ||= []

  def base_env
    { 'KERYX_HOME' => tmp('state'), 'KERYX_HOST' => 'athena', 'XDG_CONFIG_HOME' => tmp('config'), 'USER' => 'person' }
  end

  def claude(pid)
    { 'CLAUDECODE' => '1', 'CLAUDE_PID' => pid.to_s, 'CLAUDE_CODE_SESSION_ID' => "session-#{pid}",
      'CLAUDE_CODE_MESSAGING_SOCKET' => "/tmp/cc-#{pid}.sock" }
  end

  def keryx(*argv, env: {}, input: '', out: StringIO.new)
    err = StringIO.new
    terminal = Keryx::CLI::Terminal.new(out:, err:, input: StringIO.new(input), env: base_env.merge(env))
    factory = lambda do |globals|
      Keryx::App.new(env: terminal.env, cwd: '/work', as: globals[:as], clock:, herdr:, claude_socket: sockets, codex:,
                     remote:, sleeper: ->(seconds) { clock.advance(seconds) }, process: FakeProcesses.new(alive))
    end
    Run.new(Keryx.run(argv, terminal:, app_factory: factory), out.string, err.string)
  end

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
