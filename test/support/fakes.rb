# frozen_string_literal: true

class FakeRunner
  attr_reader :calls, :inputs

  def initialize(responses = {})
    @responses = responses
    @calls = []
    @inputs = []
  end

  def call(argv, env: {}, input: nil)
    @calls << [argv, env]
    @inputs << input
    key = @responses.keys.select { argv.first(it.size) == it }.max_by(&:size)
    response = key ? @responses.fetch(key) : { success: false, err: "#{argv.first}: not found" }
    response = response.call(argv) if response.respond_to?(:call)
    Keryx::Runner::Result.new(out: response.fetch(:out, ''), err: response.fetch(:err, ''),
                              success: response.fetch(:success, true))
  end

  def argvs = calls.map(&:first)
end

class FakeRemote
  attr_reader :sent, :down

  def initialize(&receive)
    @receive = receive
    @sent = []
    @down = []
  end

  def deliver(host, messages)
    if @down.include?(host)
      return Keryx::Remote::Answer.new(receipts: {}, error: "ssh: connect to host #{host} port 22: No route to host")
    end

    @sent << [host, messages.map(&:id)]
    out = @receive.call(host, messages.map { "#{it.to_json}\n" }.join)
    Keryx::Remote::Answer.new(receipts: out.each_line.to_h { JSON.parse(it).then { |r| [r['id'], r] } }, error: nil)
  end
end

class FakeHerdr
  attr_reader :prompts

  def initialize(agents = {}, screens: {}, prompt_outcome: Keryx::Herdr::Outcome.new(ok: true, code: nil, detail: nil))
    @agents = agents
    @screens = screens
    @prompt_outcome = prompt_outcome
    @prompts = []
  end

  def agent(socket, pane) = @agents[[socket, pane]]

  def agents(socket) = @agents.filter_map { |(server, _pane), agent| agent if server == socket }

  def screen(socket, pane) = @screens.fetch([socket, pane], '> ')

  def prompt(socket, pane, text)
    @prompts << [socket, pane, text]
    @prompt_outcome
  end
end
