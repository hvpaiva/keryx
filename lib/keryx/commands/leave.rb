# frozen_string_literal: true

require_relative '../cli/command'
require_relative 'join'

module Keryx
  module Commands
    class Leave < CLI::Command
      HELD = "only that session can release it, with 'keryx leave'"

      define 'leave', section: 'Session Commands',
                      summary: 'Release the address this session holds',
                      description: "Release the address this session holds.\n\n" \
                                   'The address and its mailbox stay: messages keep arriving, and the next ' \
                                   "session to join the address finds them.\n\n" \
                                   'With --as ADDRESS, release the address for a session that ended without ' \
                                   'leaving, such as one that was closed or killed, and with --as ADDRESS/SESSION ' \
                                   'release a session that join --force displaced and that ended the same way. ' \
                                   'keryx refuses while that session runs, and then ' \
                                   'only the session itself can leave. A session runs while the process keryx ' \
                                   'recorded for it runs, or, with no process recorded, until herdr shows that its ' \
                                   'pane no longer runs it. keryx cannot see a session with neither, such as a ' \
                                   'Codex session outside herdr, and releases it, so make sure it is closed before ' \
                                   'you release its address.',
                      examples: [['Release the address before handing the pane to another task', 'leave'],
                                 ['Release the address of a session that was closed without leaving',
                                  'leave --as rev-1']]

      def call(_arguments)
        return release_ended(app.me) if app.as

        left(app.store.with_occupants_lock { release })
      end

      private

      # Finding the address and removing it under one lock keeps a join or a refresh from coming in between.
      def release
        name = app.identity.held or raise Error, 'this session holds no address'
        app.store.unbind(name)
        name
      end

      def release_ended(name)
        occupant = app.store.with_occupants_lock { unbind_ended(name) }
        return left(name) if app.caller.holds?(occupant)

        terminal.puts("Released #{terminal.paint(:address, app.full(name))} from its #{Text.plain(occupant.harness)} " \
                      "session (#{Text.plain(Join.where(occupant))}), which keryx does not see running. " \
                      "#{afterwards(name)}")
        nil
      end

      def unbind_ended(name)
        occupant = app.store.occupant(name) or raise Error, "no session holds #{app.full(name)}"
        Join.refuse_taken(app, name, HELD, caller: app.caller)
        app.store.unbind(name)
        occupant
      end

      def left(name)
        terminal.puts("Left #{terminal.paint(:address, app.full(name))}. #{afterwards(name)}")
        nil
      end

      # A session address goes with its session; the address itself keeps its mailbox.
      def afterwards(name)
        name.include?('/') ? 'Mail to it is refused from now on.' : 'Its mailbox keeps receiving.'
      end
    end
  end
end
