# frozen_string_literal: true

require 'shellwords'
require_relative '../cli/command'
require_relative '../duration'
require_relative '../harness'
require_relative '../postman'
require_relative '../spawner'
require_relative '../text'
require_relative 'ask'
require_relative 'join'

module Keryx
  module Commands
    class Spawn < CLI::Command
      NOT_IN_HERDR = 'spawn places the new session next to this one, so it runs only in a herdr pane, where ' \
                     'HERDR_SOCKET_PATH and HERDR_PANE_ID are set'
      DIRECTIONS = %w[right down].freeze
      DEFAULT_TIMEOUT = '2m'
      SETTING = /\A[[:alnum:]][[:graph:]]{0,99}\z/
      LABEL = /\A[[:alnum:]][[:alnum:] ._-]{0,39}\z/
      FREE = "choose another name, or run 'keryx leave' in that session first"

      define 'spawn', section: 'Session Commands', arguments: 'NAME [TEXT] [-- HARNESS_ARGS...]', min: 1, max: 2,
                      passthrough: true,
                      summary: 'Start an agent session in a herdr pane and give it an address',
                      description: 'Start an agent session in a new herdr pane, give it the address NAME and hand it ' \
                                   "its first request.\n\n" \
                                   'spawn runs in a herdr pane and splits it, or uses the tab --tab names. It ' \
                                   'creates NAME and, when TEXT or --file gives one, posts the request from this ' \
                                   'session before the new session exists. The harness then starts with a first ' \
                                   'prompt that tells the session to join NAME, follow the keryx skill and open its ' \
                                   'inbox. spawn waits for the join and prints the address, harness, pane and ' \
                                   "request id.\n\n" \
                                   'The session starts in this directory, or in --cwd, with KERYX_HOME set to this ' \
                                   'store and KERYX_HOST passed on when it is set. Claude Code also gets the ' \
                                   'settings that let the bells in and run the stop ' \
                                   'hook, for that session only. Codex runs a new hook only after you trust it and ' \
                                   'Cursor reads hooks only from its hooks.json, so spawn installs no hook for them; ' \
                                   "'keryx hook --help' shows how to add it. Arguments after -- go to the harness " \
                                   "unchanged.\n\n" \
                                   'A dialog in the new pane, such as a folder trust or permission question, is ' \
                                   'yours to answer. spawn says so once and keeps waiting. The session holds its ' \
                                   'first prompt behind the dialog and joins once it is answered, even after spawn ' \
                                   'gave up. spawn exits with status 3 when --timeout passes first.',
                      examples: [['Start a reviewer in Claude Code with its first request',
                                  'spawn rev-1 --harness claude --role reviewer "Review PR #448"'],
                                 ['Start Codex in the agents tab with a brief from a file and a deadline',
                                  'spawn impl --harness codex --tab agents --file brief.md --within 1h'],
                                 ['Choose the model and pass the harness flags of its own',
                                  'spawn docs --harness claude --model haiku "Check the links in docs/" -- ' \
                                  '--add-dir ../site']]

      def define_options(parser)
        parser.on('--harness HARNESS', Harness::KINDS, 'Start claude, codex or cursor (required)') do |harness|
          options[:harness] = harness
        end
        parser.on('--role ROLE', 'Say what the session does, such as reviewer or implementer') do |role|
          options[:role] = role
        end
        request_options(parser)
        placement_options(parser)
        harness_options(parser)
        parser.on('--timeout DURATION', "Give up on the join after DURATION (default: #{DEFAULT_TIMEOUT})") do |time|
          options[:timeout] = time
        end
      end

      def call(arguments)
        name = Address.validate_name(arguments[0])
        text = request_text(arguments[1])
        check(name, text)
        sender = app.me if text
        claim(name)
        before = app.store.occupant(name)
        request = text && post(sender, name, text)
        waiting(request) { launch(name, before) }
        report(name, request)
      end

      private

      def request_options(parser)
        body_option(parser)
        parser.on('--within DURATION', 'Expect the reply within DURATION, such as 30m or 1h30m') do |duration|
          options[:within] = duration
        end
      end

      def placement_options(parser)
        parser.on('--split DIRECTION', DIRECTIONS, 'Split the pane right or down (default: right)') do |direction|
          options[:split] = direction
        end
        parser.on('--tab LABEL', 'Use the tab LABEL of this workspace, created when missing') do |label|
          options[:tab] = label
        end
        parser.on('--cwd PATH', 'Start the session in PATH (default: the current directory)') { options[:cwd] = it }
      end

      def harness_options(parser)
        parser.on('--model MODEL', 'Ask the harness for MODEL') { options[:model] = it }
        parser.on('--effort LEVEL', 'Ask claude or codex for this reasoning effort') { options[:effort] = it }
        parser.on('--prompt TEXT', 'Add TEXT to the first prompt the session gets') { options[:prompt] = it }
      end

      def request_text(text)
        return body(text) if text || options[:file]
        raise UsageError, '--within needs a request: give the text as an argument or with --file' if options[:within]

        nil
      end

      def check(name, text)
        Join.check_role(options[:role])
        raise UsageError, 'missing --harness: give claude, codex or cursor' unless options[:harness]

        Postman.check_body(text) if text

        %i[model effort].each { check_setting(it) }
        check_label
        timeout
        due_at
        harness_arguments(name)
        directory
        herdr_caller
      end

      def check_setting(key)
        value = options[key]
        return if value.nil? || SETTING.match?(value)

        raise UsageError, "invalid --#{key} #{value.inspect}: a letter or digit, then up to 99 printable characters " \
                          'without spaces'
      end

      def check_label
        label = options[:tab]
        return if label.nil? || LABEL.match?(label)

        raise UsageError, "invalid tab label #{label.inspect}: up to 40 letters, digits, spaces, dots, hyphens or " \
                          'underscores'
      end

      def timeout = @timeout ||= Duration.parse(options[:timeout] || DEFAULT_TIMEOUT)

      def due_at = @due_at ||= options[:within] && (app.now + Duration.parse(options[:within]))

      def directory
        @directory ||= begin
          path = File.expand_path(options[:cwd] || app.cwd, app.cwd)
          raise Error, "no directory #{path}" if options[:cwd] && !File.directory?(path)

          path
        end
      end

      def herdr_caller
        caller = app.caller
        raise Error, NOT_IN_HERDR unless caller.herdr_socket && caller.herdr_pane

        caller
      end

      def session_env
        host = app.env['KERYX_HOST'].to_s.empty? ? nil : app.host
        { 'KERYX_HOME' => app.store.root, 'KERYX_HOST' => host }.compact
      end

      def harness_arguments(name)
        @harness_arguments ||= [
          *Harness.arguments(options[:harness], name:, model: options[:model], effort: options[:effort],
                                                env: session_env),
          *checked_passthrough, '--', first_prompt(name)
        ]
      end

      def checked_passthrough
        passthrough.each do |argument|
          next unless Text::CONTROL.match?(argument)

          raise UsageError, "harness argument #{argument.inspect} holds a control character, and spawn types the " \
                            'arguments into a shell'
        end
      end

      def first_prompt(name)
        role = options[:role]
        join = Shellwords.join(['keryx', 'join', name, *(['--role', role] if role)])
        [
          "You are #{[app.full(name), role && "the #{role}"].compact.join(', ')}, started by keryx spawn.",
          "Run '#{join}', then run 'keryx skill' and follow it, then run 'keryx inbox'.",
          extra_prompt
        ].compact.join(' ')
      end

      def extra_prompt
        text = Text.plain(options[:prompt].to_s.gsub(/\s+/, ' ').strip)
        text.empty? ? nil : text
      end

      def claim(name)
        Join.refuse_taken(app, name, FREE)
        agent = app.herdr.agent(herdr_caller.herdr_socket, name)
        raise Error, "herdr already runs an agent named #{name}, in pane #{Text.plain(agent.pane)}; #{FREE}" if agent

        app.store.create_address(name, role: options[:role])
      end

      def post(sender, name, text)
        app.postman.post(sender:, recipient: Address.new(name:, host: app.host), kind: 'request', body: text,
                         due_at:).message
      end

      def waiting(request)
        yield
      rescue Error => e
        raise unless request

        raise e.class, "#{e.message}; the request #{request.id} waits in its mailbox"
      end

      def launch(name, before)
        deadline = app.now + timeout
        kind = options[:harness]
        @pane = place
        spawner.start(@pane, name:, kind:, arguments: harness_arguments(name), deadline:)
        @occupant = spawner.await_join(name, app.full(name), @pane, kind:, before:, deadline:)
      end

      def place
        spawner.place(herdr_caller.herdr_pane, split: options[:split] || DIRECTIONS.first, tab: options[:tab],
                                               cwd: directory, env: session_env).id
      end

      def spawner
        @spawner ||= Spawner.new(herdr: app.herdr, store: app.store, socket: herdr_caller.herdr_socket,
                                 clock: app.clock, sleeper: app.sleeper, notice: ->(text) { terminal.warn(text) })
      end

      def report(name, request)
        terminal.puts("Spawned #{terminal.paint(:address, app.full(name))} as a #{Text.plain(@occupant.harness)} " \
                      "session in pane #{Text.plain(@pane)}, and it joined.")
        return unless request

        terminal.puts("Its first request is #{terminal.paint(:id, request.id)}.",
                      Ask.follow_up(app.caller.agent?, request.id))
      end
    end
  end
end
