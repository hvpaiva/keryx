# frozen_string_literal: true

require_relative '../cli/command'
require_relative '../cli/spawn_help'
require_relative '../courier'
require_relative '../duration'
require_relative '../harness'
require_relative '../paths'
require_relative '../postman'
require_relative '../spawner'
require_relative '../text'
require_relative '../tokens'
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

      define 'spawn', section: 'Session Commands', arguments: 'ADDRESS [TEXT] [-- HARNESS_ARGS...]', min: 1, max: 2,
                      passthrough: true,
                      summary: 'Start an agent session in a herdr pane and give it an address',
                      description: 'Start an agent session in a new herdr pane, give it ADDRESS and hand it its ' \
                                   "first request.\n\n#{CLI::SpawnHelp::NAMING}\n\n#{CLI::SpawnHelp::PLACEMENT}\n\n" \
                                   'spawn creates the address and, when TEXT or --file gives one, posts the request ' \
                                   'from this session before the new session exists, without a bell, since nothing ' \
                                   'holds the address yet but a session that may have ended. The harness then ' \
                                   'starts with a first prompt that tells the session to join MEMBER.TEAM, follow ' \
                                   'the keryx skill and open its inbox. spawn waits for the join and prints the ' \
                                   "address, harness, pane and request id.\n\n" \
                                   'The session starts in this directory, or in --cwd, with KERYX_HOME set to this ' \
                                   'store, XDG_CONFIG_HOME to the directory this keryx reads its config from, and ' \
                                   'KERYX_HOST passed on when it is set. Claude Code also gets the settings that let ' \
                                   'the bells in and run the stop hook, for that session only. Codex runs a new hook ' \
                                   'only after you trust it and Cursor reads hooks only from its hooks.json, so ' \
                                   "spawn installs no hook for them; 'keryx hook --help' shows how to add it. " \
                                   'Arguments after -- go to the harness unchanged. They and the first prompt, ' \
                                   "--prompt included, are part of the harness's command line, which any local " \
                                   'process can read, so none of them may carry a secret; the request goes to the ' \
                                   'mailbox, in files only your user can read. spawn refuses a command line over ' \
                                   "4000 bytes on Linux or 1000 on macOS, which the pane's terminal would cut.\n\n" \
                                   "#{CLI::SpawnHelp::WAITING}\n\n" \
                                   '--ceiling goes into the join line of the first prompt, and the session spawn ' \
                                   'starts takes the address spawn runs as for its director when it joins, even ' \
                                   "after spawn gave up; 'keryx join --help' explains both.",
                      examples: [['Start a reviewer of team alpha in Claude Code with its first request',
                                  'spawn rev-1.alpha --harness claude --role reviewer "Review PR #448"'],
                                 ["Start Codex for this session's team in the agents tab, with a brief and a deadline",
                                  'spawn impl --harness codex --tab agents --file brief.md --within 1h'],
                                 ["Start one of this session's team with a model and harness flags of its own",
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
        @started = app.now
        name = Join.resolve(app, arguments[0], -> { app.own_address })
        text = request_text(arguments[1])
        check(name, text)
        sender = app.me if text
        director = sender || app.own_address
        claim(name)
        before = app.store.occupant(name)
        request = text && post(sender, name, text)
        waiting(request) { launch(name, before, director) }
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
        split = 'Split right, halving the width, or down, halving the height (default: right)'
        parser.on('--split DIRECTION', DIRECTIONS, split) { options[:split] = it }
        parser.on('--tab LABEL', 'Place the session in a tab labelled LABEL, a new one when none has room') do |label|
          options[:tab] = label
        end
        parser.on('--cwd PATH', 'Start the session in PATH (default: the current directory)') { options[:cwd] = it }
      end

      def harness_options(parser)
        parser.on('--model MODEL', 'Ask the harness for MODEL') { options[:model] = it }
        parser.on('--effort LEVEL', 'Ask claude or codex for this reasoning effort') { options[:effort] = it }
        parser.on('--prompt TEXT', 'Add TEXT, up to 2 KiB, to the first prompt the session gets') do |text|
          options[:prompt] = text
        end
        Join.ceiling_option(parser, options)
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
        Harness.check(options[:harness], **options.slice(:effort, :prompt))
        self.passthrough = Harness.passthrough(passthrough)
        check_label
        timeout
        due_at
        first_prompt(name)
        directory
        check_line(name)
      end

      # The new pane's id is not known yet, and this pane's has the same form.
      def check_line(name)
        Harness.check_line(options[:harness], harness_arguments(name, herdr_caller.herdr_pane), host_os: app.host_os)
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
        { 'KERYX_HOME' => app.store.root, 'XDG_CONFIG_HOME' => Paths.new(app.env).config_home,
          'KERYX_HOST' => host }.compact
      end

      def harness_arguments(name, pane)
        env = session_env.merge('HERDR_SOCKET_PATH' => herdr_caller.herdr_socket, 'HERDR_PANE_ID' => pane)
        [*Harness.arguments(options[:harness], name:, model: options[:model], effort: options[:effort], env:),
         *passthrough, '--', first_prompt(name)]
      end

      def first_prompt(name)
        @first_prompt ||= begin
          Tokens.parse(options[:ceiling]) if options[:ceiling]
          Harness.first_prompt(app.full(name), name:, **options.slice(:role, :ceiling), extra: options[:prompt])
        end
      end

      def claim(name)
        Join.refuse_retired(app, name, "spawn another name, or bring it back with 'keryx join #{name} --revive' from " \
                                       'the session that will hold it')
        Join.refuse_taken(app, name, FREE)
        spawner.claim_name(name, herdr_caller.herdr_pane)
        app.store.create_address(name, role: options[:role])
        # An earlier spawn's session may never have joined, and this spawn records a director only when it has one.
        app.store.forget_spawned(name)
      end

      def post(sender, name, text)
        app.postman.post(sender:, recipient: Address.from_key(name, host: app.host), kind: 'request', body: text,
                         due_at:, ring: false).message
      end

      # The request goes on the first line, since a dialog's text can follow it.
      def waiting(request)
        yield
      rescue Error => e
        raise unless request

        raise e.class, e.message.sub(/$/, "; the request #{request.id} waits in its mailbox")
      end

      def launch(name, before, director)
        @pane = place(name)
        @occupant = spawner.run(name, app.full(name), @pane, kind: options[:harness], before:, director:,
                                                             prompt: first_prompt(name),
                                                             arguments: harness_arguments(name, @pane))
      end

      def place(name)
        spawner.place(herdr_caller.herdr_pane, label: name, address: app.full(name), kind: options[:harness],
                                               split: options[:split] || DIRECTIONS.first, tab: options[:tab],
                                               cwd: directory, env: session_env).id
      end

      def spawner
        @spawner ||= Spawner.new(herdr: app.herdr, store: app.store, socket: herdr_caller.herdr_socket,
                                 clock: app.clock, sleeper: app.sleeper, deadline: @started + timeout,
                                 notice: ->(text) { terminal.warn(Text.plain(text, layout: true)) },
                                 post: method(:tell), vacant: ->(name, advice) { Join.refuse_taken(app, name, advice) })
      end

      def tell(name, body)
        app.postman.post(sender: Identity::SYSTEM, recipient: Address.from_name(name, host: app.host), kind: 'message',
                         body:)
      end

      def report(name, request)
        terminal.puts("Spawned #{terminal.paint(:address, app.full(name))} as a #{Text.plain(@occupant.harness)} " \
                      "session in pane #{Text.plain(@pane)}, and it joined.")
        return unless request

        terminal.puts("Its first request is #{terminal.paint(:id, request.id)}.",
                      Ask.follow_up(app, request.id))
      end
    end
  end
end
