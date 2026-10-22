# frozen_string_literal: true

class FakeRunner
  attr_reader :calls

  def initialize(responses = {})
    @responses = responses
    @calls = []
  end

  def call(argv, env: {})
    @calls << [argv, env]
    key = @responses.keys.select { argv.first(it.size) == it }.max_by(&:size)
    response = key ? @responses.fetch(key) : { success: false, err: "#{argv.first}: not found" }
    response = response.call(argv) if response.respond_to?(:call)
    Keryx::Runner::Result.new(out: response.fetch(:out, ''), err: response.fetch(:err, ''),
                              success: response.fetch(:success, true))
  end

  def argvs = calls.map(&:first)
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
