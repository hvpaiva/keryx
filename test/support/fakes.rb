# frozen_string_literal: true

class FakeRunner
  attr_reader :calls, :inputs, :timeouts

  def initialize(responses = {})
    @responses = responses
    @calls = []
    @inputs = []
    @timeouts = []
  end

  def call(argv, env: {}, input: nil, timeout: nil)
    @calls << [argv, env]
    @inputs << input
    @timeouts << timeout
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
  OK = Keryx::Herdr::Outcome.new(ok: true, code: nil, detail: nil)

  attr_reader :prompts, :splits, :created_tabs, :starts
  attr_accessor :start_outcome, :on_start

  def initialize(agents = {}, screens: {}, prompt_outcome: OK, panes: [], tabs: {})
    @agents = agents
    @screens = screens
    @prompt_outcome = prompt_outcome
    @prompts = []
    @panes = panes
    @tabs = tabs
    @splits = []
    @created_tabs = []
    @starts = []
    @start_outcome = OK
  end

  def agent(socket, pane) = @agents[[socket, pane]].then { it.respond_to?(:call) ? it.call : it }

  def agents(socket) = @agents.filter_map { |(server, _pane), agent| agent if server == socket }

  def put(socket, pane, agent) = @agents[[socket, pane]] = agent

  def show(socket, pane, screen) = @screens[[socket, pane]] = screen

  def screen(socket, pane) = @screens.fetch([socket, pane], '> ')

  def prompt(socket, pane, text)
    @prompts << [socket, pane, text]
    @prompt_outcome
  end

  def pane(_socket, id) = @panes.find { it.id == id } || raise(Keryx::Error, "herdr pane get failed: no pane #{id}")

  def panes(_socket, workspace) = @panes.select { it.workspace == workspace }

  def tabs(_socket, workspace) = @tabs.fetch(workspace, [])

  def split(socket, from, direction:, cwd:, env: {})
    @splits << [from, direction, cwd, env]
    parent = pane(socket, from)
    add_pane(parent.workspace, parent.tab)
  end

  def create_tab(_socket, workspace, label:, cwd:, env: {})
    @created_tabs << [workspace, label, cwd, env]
    tab = Keryx::Herdr::Tab.new(id: "#{workspace}:t#{tabs(nil, workspace).size + 1}", label:)
    (@tabs[workspace] ||= []) << tab
    add_pane(workspace, tab.id)
  end

  def start(socket, pane, name:, kind:, arguments:, timeout:)
    @starts << { pane:, name:, kind:, arguments:, timeout: }
    @on_start&.call(socket, pane, name, kind)
    @start_outcome
  end

  private

  def add_pane(workspace, tab)
    Keryx::Herdr::Pane.new(id: "#{workspace}:p#{@panes.size + 1}", tab:, workspace:).tap { @panes << it }
  end
end
