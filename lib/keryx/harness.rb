# frozen_string_literal: true

require 'json'
require 'shellwords'
require_relative 'error'
require_relative 'text'

module Keryx
  module Harness
    KINDS = %w[claude codex cursor].freeze
    # The stop hook as Cursor's hooks.json lists it; Claude Code's settings and Codex's hooks.json add its type.
    STOP_HOOK = { 'command' => 'keryx hook stop' }.freeze
    CLAUDE_HOOKS = { 'hooks' => { 'Stop' => [{ 'hooks' => [{ 'type' => 'command', **STOP_HOOK }] }] } }.freeze
    # What each harness's settings or hooks file holds to run the stop hook.
    HOOKS = { 'claude' => CLAUDE_HOOKS, 'codex' => CLAUDE_HOOKS,
              'cursor' => { 'version' => 1, 'hooks' => { 'stop' => [STOP_HOOK] } } }.freeze
    CLAUDE_SETTINGS = JSON.generate({ 'crossSessionInbound' => 'accept', **CLAUDE_HOOKS })
    # What a launcher adds to a harness's command line for keryx, for that session only.
    SESSION_ARGUMENTS = { 'claude' => ['--settings', CLAUDE_SETTINGS], 'codex' => [], 'cursor' => [] }.freeze
    # The files a harness reads its hooks from when no argument carries them, a user's and then a project's.
    HOOK_FILES = { 'codex' => %w[~/.codex/hooks.json .codex/hooks.json],
                   'cursor' => %w[~/.cursor/hooks.json .cursor/hooks.json] }.freeze
    # The channels Bell tries for a session of each kind, in the order it tries them.
    BELL = { 'claude' => %w[claude herdr], 'codex' => %w[codex herdr], 'cursor' => %w[herdr] }.freeze
    # A variable a launcher sets for a session, and what spawn sets it to, in words.
    Variable = Data.define(:name, :set_to)
    # herdr sets these in each pane it starts.
    PANE_VARIABLES = {
      socket: Variable.new('HERDR_SOCKET_PATH', 'the socket of the herdr server spawn runs under'),
      pane: Variable.new('HERDR_PANE_ID', 'the id of the pane spawn opens for the session')
    }.freeze
    # A session that should use a store other than the default gets these.
    STORE_VARIABLES = {
      home: Variable.new('KERYX_HOME', 'the store spawn itself uses'),
      config_home: Variable.new('XDG_CONFIG_HOME', 'the directory spawn reads keryx/config under'),
      host: Variable.new('KERYX_HOST', "spawn's own host, passed only when KERYX_HOST is set for spawn")
    }.freeze
    # Codex gives its commands only the variables its shell_environment_policy allows, so the session's go through it.
    CODEX_ENVIRONMENT = 'shell_environment_policy.set'
    CURSOR_EFFORT = "cursor takes no --effort; give the effort in the model, as in --model 'NAME[effort=high]'"
    PROMPT_BYTES = 2048
    # herdr types into a shell still starting, whose terminal keeps 4095 bytes of a line on Linux and 1024 on macOS.
    LINE_BYTES = { 'linux' => 4000, 'darwin' => 1000 }.freeze

    module_function

    def check(kind, effort: nil, prompt: nil)
      raise UsageError, CURSOR_EFFORT if kind == 'cursor' && effort
      return if prompt.nil? || prompt.bytesize <= PROMPT_BYTES

      raise UsageError, "--prompt is #{prompt.bytesize} bytes and the limit is #{PROMPT_BYTES}: the first prompt is " \
                        "part of the harness's command line, which any local process can read. Give longer " \
                        'instructions as the request, with TEXT or --file, which goes to the mailbox instead.'
    end

    # Under an ASCII locale Ruby reads every argument as binary, so each one is taken as the UTF-8 a harness expects.
    def passthrough(arguments)
      arguments.map do |argument|
        text = String.new(argument, encoding: Encoding::UTF_8)
        raise UsageError, "harness argument #{text.inspect} is not valid UTF-8" unless text.valid_encoding?
        next text unless Text::CONTROL.match?(text)

        raise UsageError, "harness argument #{text.inspect} holds a control character, and spawn types the " \
                          'arguments into a shell'
      end
    end

    def check_line(kind, arguments, host_os:)
      bytes = command_line(kind, arguments).bytesize
      limit = LINE_BYTES.fetch(host_os[/\A[a-z]+/], LINE_BYTES['darwin'])
      return if bytes <= limit

      raise UsageError, "the command herdr would type into the new pane's shell is #{bytes} bytes, and a shell line " \
                        "holds at most #{limit} here before the terminal cuts it; give long text as the request, " \
                        'with TEXT or --file, and long values such as PATH through the environment of the pane ' \
                        "(the shell's rc or the herdr server's environment) rather than as harness arguments"
    end

    # The line herdr agent start types, taken as each word single-quoted, which is close to what herdr does.
    def command_line(kind, arguments) = [kind, *arguments].map { "'#{it.b.gsub("'") { "'\\''" }}'" }.join(' ')

    def arguments(kind, name:, model: nil, effort: nil, env: {})
      case kind
      when 'claude' then claude(name, model, effort)
      when 'codex' then codex(model, effort, env)
      else option('--model', model)
      end
    end

    def claude(name, model, effort)
      ['-n', name, '--remote-control', name, *option('--model', model), *option('--effort', effort),
       *SESSION_ARGUMENTS.fetch('claude')]
    end

    def codex(model, effort, env)
      settings = { 'model' => model, 'model_reasoning_effort' => effort }.compact
      settings.merge!(env.transform_keys { "#{CODEX_ENVIRONMENT}.#{it}" })
      settings.flat_map { |key, value| ['-c', "#{key}=#{JSON.generate(value)}"] }
    end

    def option(flag, value) = value ? [flag, value] : []

    def store_env(home:, config_home:, host:) = named(STORE_VARIABLES, { home:, config_home:, host: })

    def pane_env(socket:, pane:) = named(PANE_VARIABLES, { socket:, pane: })

    # The variables by name, leaving out a nil value.
    def named(variables, values) = variables.to_h { |key, variable| [variable.name, values.fetch(key)] }.compact

    # A hooks file's entry as one line a person can paste.
    def hooks_line(kind) = JSON.generate(HOOKS.fetch(kind), space: ' ', object_nl: ' ', array_nl: ' ')

    def first_prompt(address, name:, role: nil, ceiling: nil, extra: nil)
      join = Shellwords.join(['keryx', 'join', name, *option('--role', role), *option('--ceiling', ceiling)])
      extra = Text.plain(extra.to_s.gsub(/\s+/, ' ').strip)
      [
        "You are #{[address, role && "the #{role}"].compact.join(', ')}, started by keryx spawn.",
        "Run '#{join}', then run 'keryx skill' and follow it, then run 'keryx inbox'.",
        (extra unless extra.empty?)
      ].compact.join(' ')
    end
  end
end
