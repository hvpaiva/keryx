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

      define 'join', section: 'Session Commands', arguments: 'ADDRESS', min: 1, max: 1,
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

      # The store name of the address TEXT names, for a session acting as SENDER. A person's own address may be held by
      # a session that relays for them; no other address in a reserved scope may be.
      def self.resolve(app, text, sender)
        address = app.resolver.resolve(text, sender:)
        raise Error, "#{address} is on another machine; a session holds an address on #{app.host}" unless
          address.local?(app.host)
        raise UsageError, "#{address} names one session; give the address without /#{address.session}" if
          address.session
        return address.key unless address.reserved? && address.key != app.identity.human_name

        raise Error, "#{address} is in a reserved scope: #{Address::LOCAL} is a person at a terminal, as " \
                     "#{app.full(app.identity.human_name)}, and #{Address::SYSTEM} is keryx's own services"
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
        name = address(arguments.first)
        Join.check_role(options[:role])
        caller = app.caller
        raise Error, NOT_AN_AGENT unless caller.agent?

        occupant = app.session_occupant(app.now).with(ceiling: options[:ceiling] && Tokens.parse(options[:ceiling]))
        displaced = app.store.with_occupants_lock { claim(name, caller, occupant) }
        report(name, occupant, displaced)
      end

      private

      # A bare member joins the team of the address the session holds.
      def address(text) = Join.resolve(app, text, -> { app.identity.held })

      def claim(name, caller, occupant)
        Join.refuse_retired(app, name, 'pass --revive to bring it back with its mailbox') unless options[:revive]
        refuse_taken(name, caller)
        release_others(name, caller)
        app.store.revive(name) if options[:revive]
        app.store.create_address(name, role: options[:role])
        take(name, caller, occupant)
      end

      # The session the address is taken from, when it still runs elsewhere, stays bound at its session address, which
      # this returns. A session displaced earlier stays bound only while it runs.
      def take(name, caller, occupant)
        app.store.outgoing(name).map { "#{name}/#{it}" }.each do |incarnation|
          app.store.unbind(incarnation) unless elsewhere?(incarnation, caller)
        end
        displaced = displace(name) if elsewhere?(name, caller)
        app.store.bind(name, directed(name, occupant.with(session: Address.draw_session(app.store.outgoing(name)))))
        app.store.forget_spawned(name)
        displaced
      end

      def elsewhere?(name, caller)
        occupant = app.store.reporting { app.store.occupant(name) }
        !occupant.nil? && !caller.holds?(occupant) && app.roster.live?(occupant)
      end

      def displace(name)
        current = app.store.occupant(name)
        current = current.with(session: Address.draw_session(app.store.outgoing(name))) unless current.session
        app.store.displace(name, current)
        "#{name}/#{current.session}"
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
        (app.store.address_names - [name]).flat_map { app.store.incarnations(it) }.each do |other|
          occupant = app.store.reporting { app.store.occupant(other) }
          app.store.unbind(other) if occupant && caller.holds?(occupant)
        end
      end

      def ceiling(occupant) = occupant.ceiling ? " Its context ceiling is #{Tokens.short(occupant.ceiling)}." : ''

      def report(name, occupant, displaced)
        terminal.puts("Joined #{terminal.paint(:address, app.full(name))} as a #{Text.plain(occupant.harness)} " \
                      "session (#{Text.plain(Join.where(occupant))}).#{ceiling(occupant)}")
        if displaced
          terminal.puts('The session that held it stays reachable at ' \
                        "#{terminal.paint(:address, app.full(displaced))} until it leaves.")
        end
        unread = app.store.unread(name).size
        terminal.puts("#{unread} unread message(s) waiting; run 'keryx inbox'.") if unread.positive?
        nil
      end
    end
  end
end
