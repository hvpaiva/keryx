# frozen_string_literal: true

require 'json'
require_relative 'error'

module Keryx
  module Harness
    KINDS = %w[claude codex cursor].freeze
    CLAUDE_SETTINGS = JSON.generate(
      'crossSessionInbound' => 'accept',
      'hooks' => { 'Stop' => [{ 'hooks' => [{ 'type' => 'command', 'command' => 'keryx hook stop' }] }] }
    )
    CURSOR_EFFORT = "cursor takes no --effort; give the effort in the model, as in --model 'NAME[effort=high]'"

    module_function

    def arguments(kind, name:, model: nil, effort: nil, env: {})
      case kind
      when 'claude' then claude(name, model, effort)
      when 'codex' then codex(model, effort, env)
      else cursor(model, effort)
      end
    end

    def claude(name, model, effort)
      ['-n', name, '--remote-control', name, *option('--model', model), *option('--effort', effort),
       '--settings', CLAUDE_SETTINGS]
    end

    # Codex passes its commands only the variables its shell_environment_policy allows, so KERYX_* go through it.
    def codex(model, effort, env)
      settings = { 'model' => model, 'model_reasoning_effort' => effort }.compact
      settings.merge!(env.transform_keys { "shell_environment_policy.set.#{it}" })
      settings.flat_map { |key, value| ['-c', "#{key}=#{JSON.generate(value)}"] }
    end

    def cursor(model, effort)
      raise UsageError, CURSOR_EFFORT if effort

      option('--model', model)
    end

    def option(flag, value) = value ? [flag, value] : []
  end
end
