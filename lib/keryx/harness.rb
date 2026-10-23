# frozen_string_literal: true

require 'json'
require 'shellwords'
require_relative 'error'
require_relative 'text'

module Keryx
  module Harness
    KINDS = %w[claude codex cursor].freeze
    CLAUDE_SETTINGS = JSON.generate(
      'crossSessionInbound' => 'accept',
      'hooks' => { 'Stop' => [{ 'hooks' => [{ 'type' => 'command', 'command' => 'keryx hook stop' }] }] }
    )
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
       '--settings', CLAUDE_SETTINGS]
    end

    # Codex passes its commands only the variables its shell_environment_policy allows, so the session's go through it.
    def codex(model, effort, env)
      settings = { 'model' => model, 'model_reasoning_effort' => effort }.compact
      settings.merge!(env.transform_keys { "shell_environment_policy.set.#{it}" })
      settings.flat_map { |key, value| ['-c', "#{key}=#{JSON.generate(value)}"] }
    end

    def option(flag, value) = value ? [flag, value] : []

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
