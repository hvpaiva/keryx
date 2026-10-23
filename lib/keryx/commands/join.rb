# frozen_string_literal: true

require_relative '../cli/command'
require_relative '../tokens'

module Keryx
  module Commands
    class Join < CLI::Command
      NOT_AN_AGENT = 'join binds the agent session that runs it; run it from inside a Claude Code, Codex or ' \
                     'Cursor session, or from an agent running in a herdr pane'
      SESSION_LABEL = { 'codex' => 'thread', 'cursor' => 'conversation' }.freeze
      ROLE = /\A[[:alnum:]][[:alnum:] ._-]{0,39}\z/
      CEILING = 'A ceiling is a number of tokens, such as 125k, kept with the session. Once its context reaches ' \
                '80% of the ceiling, and again once it reaches the ceiling, keryx courier tells the session and its ' \
                'director: the address that spawned it, or else the sender of its oldest open request. Windows ' \
                'differ by harness and model (Claude Code runs 200K or 1M, Codex and Cursor show theirs in keryx ' \
                'who), so no one share fits them all. Choose the ceiling below the window, at the point where the ' \
                'session should reach a stopping point and hand over. There is no ceiling unless one is given.'

      define 'join', section: 'Session Commands', arguments: 'NAME', min: 1, max: 1,
                     summary: 'Claim an address for this agent session',
                     description: "Claim an address for the agent session that runs this command.\n\n" \
                                  'The address is created if it does not exist and outlives the session: when ' \
                                  'the session ends, its mailbox keeps receiving, and the next session to join ' \
                                  'the name finds the messages waiting. A session holds one address at a time, ' \
                                  "so joining another releases the first.\n\n" \
                                  'A retired address is refused unless --revive is given, which takes it back with ' \
                                  "its mailbox as it was; 'keryx retire --help' says what retiring does.\n\n" \
                                  "#{CEILING}",
                     examples: [['Join as the first reviewer', 'join rev-1 --role reviewer'],
                                ['Join with a context ceiling of 125k tokens', 'join impl --ceiling 125k'],
                                ['Take an address over from a session that is still running', 'join rev-1 --force'],
                                ['Take back an address that was retired', 'join rev-1 --revive']]

      def self.where(session)
        label = SESSION_LABEL[session.harness]
        parts = [session.pid && "pid #{session.pid}", label && session.session_id && "#{label} #{session.session_id}",
                 session.herdr_pane && "pane #{session.herdr_pane}"].compact
        parts.empty? ? 'no pid, thread or pane known' : parts.join(', ')
      end

      def self.check_role(role)
        return if role.nil? || ROLE.match?(role)

        raise UsageError, "invalid role #{role.inspect}: up to 40 letters, digits, spaces, dots, hyphens or underscores"
      end

      def self.refuse_retired(app, name, advice)
        raise Error, "#{app.full(name)} is retired; #{advice}" if app.store.retired?(name)
      end

      def self.refuse_taken(app, name, advice, caller: nil)
        occupant = app.store.occupant(name)
        return if occupant.nil? || caller&.holds?(occupant)
        return unless app.roster.live?(occupant)

        raise Error, "#{app.full(name)} is held by another live #{occupant.harness} session " \
                     "(#{where(occupant)}); #{advice}"
      end

      def define_options(parser)
        parser.on('--role ROLE', 'Say what the session does, such as reviewer or implementer') do |role|
          options[:role] = role
        end
        parser.on('--force', 'Take the address even when another live session holds it') { options[:force] = true }
        parser.on('--revive', 'Take the address back from retirement, with its mailbox') { options[:revive] = true }
        Join.ceiling_option(parser, options)
      end

      def self.ceiling_option(parser, options)
        parser.on('--ceiling TOKENS', 'Be told when the context nears TOKENS, such as 125k') do |ceiling|
          options[:ceiling] = ceiling
        end
      end

      def call(arguments)
        name = Address.validate_name(arguments.first)
        Join.check_role(options[:role])
        caller = app.caller
        raise Error, NOT_AN_AGENT unless caller.agent?

        occupant = app.session_occupant(app.now).with(ceiling: options[:ceiling] && Tokens.parse(options[:ceiling]))
        app.store.with_occupants_lock { claim(name, caller, occupant) }
        report(name, occupant)
      end

      private

      def claim(name, caller, occupant)
        Join.refuse_retired(app, name, 'pass --revive to bring it back with its mailbox') unless options[:revive]
        refuse_taken(name, caller)
        release_others(name, caller)
        app.store.revive(name) if options[:revive]
        app.store.create_address(name, role: options[:role])
        app.store.bind(name, directed(name, occupant))
        app.store.forget_spawned(name)
      end

      # The director spawn recorded goes to the session spawn started, and only on the first join after it.
      def directed(name, occupant)
        spawned = app.store.spawned(name)
        spawned&.started?(occupant) ? occupant.with(director: spawned.director) : occupant
      end

      def refuse_taken(name, caller)
        Join.refuse_taken(app, name, 'pass --force to take it over', caller:) unless options[:force]
      end

      def release_others(name, caller)
        (app.store.address_names - [name]).each do |other|
          occupant = app.store.reporting { app.store.occupant(other) }
          app.store.unbind(other) if occupant && caller.holds?(occupant)
        end
      end

      def ceiling(occupant) = occupant.ceiling ? " Its context ceiling is #{Tokens.short(occupant.ceiling)}." : ''

      def report(name, occupant)
        terminal.puts("Joined #{terminal.paint(:address, app.full(name))} as a #{Text.plain(occupant.harness)} " \
                      "session (#{Text.plain(Join.where(occupant))}).#{ceiling(occupant)}")
        unread = app.store.unread(name).size
        terminal.puts("#{unread} unread message(s) waiting; run 'keryx inbox'.") if unread.positive?
        nil
      end
    end
  end
end
