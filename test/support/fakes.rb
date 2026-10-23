# frozen_string_literal: true

class FakeRunner
  Job = Struct.new(:result, :stopped) do
    def done?(**) = true

    def stop = self.stopped = true
  end

  attr_reader :calls, :inputs, :jobs

  def initialize(responses = {})
    @responses = responses
    @calls = []
    @inputs = []
    @jobs = []
  end

  def start(argv, env: {}, input: nil) = Job.new(call(argv, env:, input:), false).tap { @jobs << it }

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
  OK = Keryx::Herdr::Outcome.new(ok: true, code: nil, detail: nil)

  # Polls before herdr agent start returns; Float::INFINITY keeps it waiting until spawn stops it.
  class Starting
    attr_reader :stopped

    def initialize(outcome, polls)
      @outcome = outcome
      @polls = polls
    end

    def outcome = (@polls -= 1).negative? ? @outcome : nil

    def stop = @stopped = true
  end

  attr_reader :prompts, :splits, :created_tabs, :starts, :renames, :foregrounds, :unanswered, :footers
  attr_writer :sizes
  # area is the size of a tab herdr creates.
  attr_accessor :start_outcome, :start_polls, :on_start, :rename_error, :layout_error, :area, :clear_error
  # Called with the name of a herdr call, such as :split or :rename, while it runs, so a test can make it slow.
  attr_accessor :on_call

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
    @renames = []
    @foregrounds = {}
    @unanswered = []
    @footers = {}
    @start_outcome = OK
    @start_polls = 0
  end

  def agent(socket, pane) = @agents[[socket, pane]].then { it.respond_to?(:call) ? it.call : it }

  def look(socket, pane) = unanswered.include?([socket, pane]) ? nil : agent(socket, pane) || Keryx::Herdr::NONE

  def foreground(socket, pane) = foregrounds[[socket, pane]]

  def agents(socket) = @agents.filter_map { |(server, _pane), agent| agent if server == socket }

  def put(socket, pane, agent) = @agents[[socket, pane]] = agent

  def show(socket, pane, screen) = @screens[[socket, pane]] = screen

  def screen(socket, pane) = @screens.fetch([socket, pane], '> ')

  def footer(socket, pane) = footers[[socket, pane]]

  # The pane as a person sees it by pane, by default what the detection screen shows; a lambda gives each read in turn.
  def views = @views ||= {}

  def visible(socket, pane)
    view = views.fetch([socket, pane]) { screen(socket, pane) }
    view.respond_to?(:call) ? view.call : view
  end

  def prompt(socket, pane, text)
    @prompts << [socket, pane, text]
    @prompt_outcome
  end

  def pane(_socket, id) = @panes.find { it.id == id } || raise(Keryx::Error, "herdr pane get failed: no pane #{id}")

  def panes(_socket, workspace) = @panes.select { it.workspace == workspace }

  def tabs(_socket, workspace) = @tabs.fetch(workspace, [])

  # [width, height] by pane id; a pane without a size has no layout.
  def sizes = @sizes ||= {}

  def layouts = @layouts ||= []

  def layout(socket, id)
    layouts << id
    on_call&.call(:layout)
    raise Keryx::Error, layout_error if layout_error

    tab = pane(socket, id).tab
    rects = @panes.select { it.tab == tab && sizes[it.id] }.map do |listed|
      Keryx::Herdr::Rect.new(pane: listed.id, width: sizes[listed.id][0], height: sizes[listed.id][1])
    end
    rects.empty? ? raise(Keryx::Error, 'herdr answered without a pane layout') : rects
  end

  def split(socket, from, direction:, cwd:, env: {})
    @splits << [from, direction, cwd, env]
    on_call&.call(:split)
    parent = pane(socket, from)
    add_pane(parent.workspace, parent.tab).tap { halve(from, it.id, direction) }
  end

  def create_tab(_socket, workspace, label:, cwd:, env: {})
    @created_tabs << [workspace, label, cwd, env]
    on_call&.call(:create_tab)
    tab = Keryx::Herdr::Tab.new(id: "#{workspace}:t#{tabs(nil, workspace).size + 1}", label:)
    (@tabs[workspace] ||= []) << tab
    add_pane(workspace, tab.id).tap { sizes[it.id] = area.dup if area }
  end

  def rename(socket, pane, label)
    on_call&.call(:rename)
    raise Keryx::Error, rename_error if rename_error

    @renames << [socket, pane, label]
  end

  def cleared = @cleared ||= []

  def clear_name(socket, pane)
    on_call&.call(:clear_name)
    raise Keryx::Error, clear_error if clear_error

    cleared << [socket, pane]
  end

  def start(socket, pane, name:, kind:, arguments:, timeout:)
    starting = Starting.new(@start_outcome, @start_polls)
    @starts << { pane:, name:, kind:, arguments:, timeout:, starting: }
    @on_start&.call(socket, pane, name, kind)
    starting
  end

  private

  def add_pane(workspace, tab)
    Keryx::Herdr::Pane.new(id: "#{workspace}:p#{@panes.size + 1}", tab:, workspace:).tap { @panes << it }
  end

  # As herdr splits: the pane keeps the larger half and the new pane gets the floor of half.
  def halve(from, pane, direction)
    size = sizes[from] or return
    axis = direction == 'down' ? 1 : 0
    sizes[pane] = size.dup.tap { it[axis] = size[axis] / 2 }
    sizes[from] = size.dup.tap { it[axis] -= size[axis] / 2 }
  end
end
