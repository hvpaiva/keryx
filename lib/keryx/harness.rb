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

    module_function

    def check(kind, effort:)
      raise UsageError, CURSOR_EFFORT if kind == 'cursor' && effort
    end

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
