# frozen_string_literal: true

require_relative '../cli/command'

module Keryx
  module Commands
    class Join < CLI::Command
      NOT_AN_AGENT = 'join binds the agent session that runs it; run it from inside a Claude Code session, or ' \
                     'from an agent running in a herdr pane'
      LIVE_SESSIONS = %w[live idle working blocked done].freeze
      ROLE = /\A[[:alnum:]][[:alnum:] ._-]{0,39}\z/

      define 'join', section: 'Session Commands', arguments: 'NAME', min: 1, max: 1,
                     summary: 'Claim an address for this agent session',
                     description: "Claim an address for the agent session that runs this command.\n\n" \
                                  'The address is created if it does not exist and outlives the session: when ' \
                                  'the session ends, its mailbox keeps receiving, and the next session to join ' \
                                  'the name finds the messages waiting. A session holds one address at a time, ' \
                                  'so joining another releases the first.',
                     examples: [['Join as the first reviewer', 'join rev-1 --role reviewer'],
                                ['Take an address over from a session that is still running', 'join rev-1 --force']]

      def self.where(session)
        parts = [session.pid && "pid #{session.pid}", session.herdr_pane && "pane #{session.herdr_pane}"].compact
        parts.empty? ? 'no pid or pane known' : parts.join(', ')
      end

      def define_options(parser)
        parser.on('--role ROLE', 'Say what the session does, such as reviewer or implementer') do |role|
          options[:role] = role
        end
        parser.on('--force', 'Take the address even when another live session holds it') { options[:force] = true }
      end

      def call(arguments)
        name = Address.validate_name(arguments.first)
        check_role(options[:role])
        caller = app.caller
        raise Error, NOT_AN_AGENT unless caller.agent?

        refuse_taken(name, caller)
        release_others(name, caller)
        app.store.create_address(name, role: options[:role])
        app.store.bind(name, caller.occupant(app.now))
        report(name, caller)
      end

      private

      def check_role(role)
        return if role.nil? || ROLE.match?(role)

        raise UsageError, "invalid role #{role.inspect}: up to 40 letters, digits, spaces, dots, hyphens or underscores"
      end

      def refuse_taken(name, caller)
        occupant = app.store.occupant(name)
        return if occupant.nil? || caller.holds?(occupant) || options[:force]
        return unless LIVE_SESSIONS.include?(app.roster.session(occupant))

        raise Error, "#{app.full(name)} is held by another live #{occupant.harness} session " \
                     "(#{Join.where(occupant)}); pass --force to take it over"
      end

      def release_others(name, caller)
        (app.store.address_names - [name]).each do |other|
          occupant = app.store.occupant(other)
          app.store.unbind(other) if occupant && caller.holds?(occupant)
        end
      end

      def report(name, caller)
        terminal.puts("Joined #{terminal.paint(:address, app.full(name))} as a #{Text.plain(caller.harness)} " \
                      "session (#{Text.plain(Join.where(caller))}).")
        unread = app.store.unread(name).size
        terminal.puts("#{unread} unread message(s) waiting; run 'keryx inbox'.") if unread.positive?
        nil
      end
    end
  end
end
