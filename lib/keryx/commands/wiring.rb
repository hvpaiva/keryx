# frozen_string_literal: true

require_relative '../cli/command'
require_relative '../harness'

module Keryx
  module Commands
    class Wiring < CLI::Command
      TRUST = { 'codex' => 'Codex runs a new hook only after it is trusted in /hooks' }.freeze
      CHANNELS = { 'claude' => "Claude Code's peer socket, which crossSessionInbound lets the bell into",
                   'codex' => "codex queue, for the thread herdr shows in the session's pane",
                   'herdr' => 'typed into the herdr pane the session runs in' }.freeze
      ENVIRONMENT = 'environment'
      CODEX_THROUGH = "-c #{Harness::CODEX_ENVIRONMENT}.NAME=VALUE".freeze
      SHELL_WORD = %r{\A[\w@%+=:,./-]+\z}
      JSON_FIELDS = 'With -o json it gives harness; host, the host name this keryx resolves, from KERYX_HOST, ' \
                    'else host in its config file, else the machine\'s short name; arguments, the list to add; ' \
                    'hooks, null when the arguments ' \
                    'carry the stop hook, or else entry, the JSON object its file holds, files, where it goes, and ' \
                    'trust, what the harness asks before it runs a new hook, or null; bell, the channels in the ' \
                    'order the bell tries them, of claude, codex and herdr; and environment, with pane and store, ' \
                    'each a list of name and set_to, what spawn sets the variable to, in words, and through, ' \
                    "#{ENVIRONMENT} when the session's commands take the variables from the harness's environment, " \
                    "or else the argument #{CODEX_THROUGH} that Codex's commands take them through.".freeze

      define 'wiring', section: 'Other Commands', arguments: 'HARNESS', min: 1, max: 1,
                       summary: 'Print what a launcher gives a session of a harness',
                       description: 'Print what a launcher gives a session of HARNESS, which is claude, codex or ' \
                                    'cursor, for keryx to reach it: the arguments to add to the command line, the ' \
                                    'stop hook and the files it goes in, the channels the bell tries in order, and ' \
                                    'the variables of the herdr pane and of the store, and the host name this ' \
                                    'keryx resolves. keryx spawn gives its sessions the same, from the same ' \
                                    'source, and apart from the host the output holds no value of this machine, ' \
                                    'so it is the same for every launcher on any machine with the same keryx. A ' \
                                    'launcher that does not read keryx\'s config file passes the host as ' \
                                    'KERYX_HOST, so the session uses the same name, and wiring fails as other ' \
                                    "commands do when the host cannot be resolved.\n\n" \
                                    'Claude Code takes --disallowedTools AskUserQuestion, which denies it the tool ' \
                                    'that asks the person at its terminal in a dialog, so that it asks through keryx ' \
                                    'instead, and --settings with crossSessionInbound accept, which lets the bells ' \
                                    'in, and the stop hook, for that session only. The deny is a flag of its own, ' \
                                    'since a later --settings replaces the permissions of an earlier one, and it ' \
                                    'comes first, since it reads every word up to the next option as a tool name. ' \
                                    "Its bell goes through Claude Code's peer socket and else its herdr pane. Codex " \
                                    "reads the stop hook from ~/.codex/hooks.json or a project's .codex/hooks.json " \
                                    'and runs a new hook only after it is trusted in /hooks. Its bell queues through ' \
                                    'codex queue for a thread herdr shows in its pane and else types into the pane, ' \
                                    'so a Codex session runs in a herdr pane, which sets HERDR_SOCKET_PATH and ' \
                                    'HERDR_PANE_ID. Cursor reads the stop hook from ~/.cursor/hooks.json or a ' \
                                    "project's .cursor/hooks.json, and its bell only types into its herdr pane.\n\n" \
                                    'A launcher passes KERYX_HOME, XDG_CONFIG_HOME and KERYX_HOST only when the ' \
                                    'session should use a store other than the default, and the output says what ' \
                                    "spawn sets each one to. Claude Code's and Cursor's commands take them from " \
                                    "the session's environment, and Codex's get them only through " \
                                    "#{CODEX_THROUGH}, with VALUE a quoted TOML string, which spawn passes along " \
                                    "with the pane's variables.\n\n#{JSON_FIELDS} #{SCHEMA_HELP}",
                       examples: [['What to add when you start Claude Code yourself', 'wiring claude'],
                                  ['What a launcher reads before it starts a Codex session', 'wiring codex -o json']]

      def define_options(parser) = output_option(parser)

      def call(arguments)
        kind = arguments.first
        unless Harness::KINDS.include?(kind)
          raise UsageError, "unknown harness #{kind.inspect}; the harnesses are #{Harness::KINDS.join(', ')}"
        end

        data = record(kind)
        json? ? print_json(data) : show(data)
        nil
      end

      private

      def record(kind)
        { 'harness' => kind, 'host' => app.host, 'arguments' => Harness::SESSION_ARGUMENTS.fetch(kind),
          'hooks' => hooks(kind), 'bell' => Harness::BELL.fetch(kind),
          'environment' => { 'pane' => variables(Harness::PANE_VARIABLES),
                             'store' => variables(Harness::STORE_VARIABLES),
                             'through' => kind == 'codex' ? CODEX_THROUGH : ENVIRONMENT } }
      end

      def hooks(kind)
        files = Harness::HOOK_FILES[kind] or return
        { 'entry' => Harness::HOOKS.fetch(kind), 'files' => files, 'trust' => TRUST[kind] }
      end

      def variables(variables) = variables.values.map { { 'name' => it.name, 'set_to' => it.set_to } }

      def show(data)
        environment = data['environment']
        terminal.puts([arguments_section(data['arguments']), hooks_section(data),
                       section('Bell, in the order it tries', rows(data['bell'].to_h { [it, CHANNELS.fetch(it)] })),
                       section('Pane variables, which herdr sets in each pane it starts', rows(environment['pane'])),
                       section('Store variables, for a store other than the default', rows(environment['store'])),
                       through(environment['through']), "This keryx resolves its host as #{data['host']}."]
                         .join("\n\n"))
      end

      def arguments_section(arguments)
        return section('Arguments to add', ['none']) if arguments.empty?

        section('Arguments to add, for that session only', [arguments.map { quoted(it) }.join(' ')])
      end

      def hooks_section(data)
        hooks = data['hooks']
        return section('Hooks', ['none, since the arguments carry the stop hook']) unless hooks

        section("Hooks, in #{hooks['files'].join(' or ')}",
                [Harness.hooks_line(data['harness']), hooks['trust']&.then { "#{it}." }].compact)
      end

      def through(form)
        return "The session's commands take these variables from the harness's environment." if form == ENVIRONMENT

        "Codex's commands get these variables only through #{form}, with VALUE a quoted TOML string."
      end

      def section(title, lines) = [terminal.paint(:header, "#{title}:"), *lines.map { "  #{it}" }].join("\n")

      def rows(entries)
        pairs = entries.is_a?(Hash) ? entries.to_a : entries.map { [it['name'], it['set_to']] }
        width = pairs.map { it.first.size }.max
        pairs.map { |term, text| "#{term.ljust(width)}   #{text}" }
      end

      def quoted(word) = SHELL_WORD.match?(word) ? word : "'#{word.gsub("'") { "'\\''" }}'"
    end
  end
end
