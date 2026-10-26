# frozen_string_literal: true

require_relative '../cli/activity_view'
require_relative '../cli/address_view'
require_relative '../cli/command'
require_relative '../cli/context_view'
require_relative '../cli/join_view'
require_relative '../cli/short_view'
require_relative '../cli/table'
require_relative '../courier'

module Keryx
  module Commands
    class Who < CLI::Command
      SESSION_ROLES = { 'none' => :muted, 'gone' => :failed, 'blocked' => :deferred, 'unknown' => :muted }.freeze
      CONTEXT = 'CONTEXT is the tokens in the context of the session, read from its harness as the command runs: the ' \
                'transcript Claude Code writes, the rollout Codex writes, or the footer Cursor shows in its herdr ' \
                'pane. When the harness reports the window, the window and the share of it in use follow, as in ' \
                "137k/258k 53%; Claude Code's transcript does not say the window, so it shows tokens only. With a " \
                'context ceiling (keryx join --help) it shows the tokens, their share of the ceiling and the ' \
                'ceiling, as in 101k 81% of 125k, in yellow from 80% and red at the ceiling. It is unknown when ' \
                'keryx could not read it, and - when no session runs.'
      ACTIVE = 'ACTIVE is how long ago the harness last wrote the file it keeps for the session: the transcript ' \
               'Claude Code writes, the rollout Codex writes, or the store Cursor keeps for the conversation under ' \
               '~/.cursor/chats. It is the time of the last write and nothing in the file, so a session on a long ' \
               'tool call looks quiet; it is not a liveness check. It is unknown when keryx could not tell, and - ' \
               'when no session runs. With -o json, last_activity is that time in ISO 8601 UTC, or null.'
      JSON_FIELDS = 'Each of the addresses -o json lists has address, member, team, host, session_address (the ' \
                    'address that reaches its session alone, or null), role, director (as DIRECTOR shows it, or ' \
                    'null for -), harness, session, last_activity, context (an object with used and window, or ' \
                    'null), ceiling, unread and join. ' \
                    "#{CLI::JoinView::HELP}".freeze

      define 'who', section: 'Session Commands',
                    summary: 'List the addresses on this machine',
                    description: "List the addresses on this machine and the sessions holding them.\n\n" \
                                 "#{CLI::ShortView::HELP} The last line says how many it left out, and --all " \
                                 'lists every address. With -o json, view says which list it is, short or all, and ' \
                                 "hidden how many addresses it left out.\n\n" \
                                 'DIRECTOR is the address keryx spawn recorded as the director of the session it ' \
                                 'started, which the courier tells when the session stops at a dialog (keryx ' \
                                 "courier --help). It is - when spawn recorded none, recorded the session's own " \
                                 "address, or recorded an address retired here.\n\n" \
                                 'SESSION is none when no session holds the address, gone when the session ended, ' \
                                 "live when its process runs, or herdr's view of the agent (idle, working, " \
                                 'blocked, done) when herdr sees it in its pane, which a session herdr relaunched ' \
                                 "there under a new process still is.\n\n" \
                                 "#{CONTEXT}\n\n#{ACTIVE}\n\n#{JSON_FIELDS} #{SCHEMA_HELP}",
                    examples: [['See who can receive messages', 'who'],
                               ['List every address, those nobody holds included', 'who --all'],
                               ['List addresses for a script', 'who -o json']]

      def define_options(parser)
        CLI::ShortView.option(parser, options)
        output_option(parser)
      end

      def call(_arguments)
        roster = app.roster
        entries = roster.entries
        view = CLI::ShortView.of(entries, all: options[:all]) { roster.open_requests }
        return print_json(json(view)) if json?
        return terminal.puts('No addresses yet. A session joins one with: keryx join MEMBER.TEAM') if entries.empty?

        print_table(view.entries)
        view.note('who')&.then { terminal.puts(terminal.paint(:muted, it)) }
      end

      private

      def print_table(entries)
        return if entries.empty?

        terminal.puts(CLI::Table.render(terminal, %w[ADDRESS ROLE DIRECTOR HARNESS SESSION ACTIVE CONTEXT UNREAD],
                                        entries.map { row(it) }))
      end

      def json(view) = { 'view' => view.name, 'hidden' => view.hidden, 'addresses' => view.entries.map { record(it) } }

      def row(entry)
        [[:address, app.full(entry.name)], entry.role || '-', director(entry) || '-', entry.occupant&.harness || '-',
         [SESSION_ROLES[entry.session], entry.session], CLI::ActivityView.cell(app, entry),
         CLI::ContextView.cell(app, entry), unread(entry.unread)]
      end

      def unread(count) = count.positive? ? [:unread, count.to_s] : '0'

      def record(entry)
        { 'address' => app.full(entry.name), **CLI::AddressView.record(app, entry.name, entry.occupant),
          'role' => entry.role, 'director' => director(entry), 'harness' => entry.occupant&.harness,
          'session' => entry.session,
          'last_activity' => CLI::ActivityView.record(app, entry), 'context' => CLI::ContextView.record(app, entry),
          'ceiling' => entry.occupant&.ceiling, 'unread' => entry.unread,
          'join' => CLI::JoinView.record(entry.occupant) }
      end

      def director(entry)
        director = Keryx::Courier.director(app.store, app.roster, entry.name, entry.occupant, host: app.host) or return
        director.to_s unless app.store.retired?(director.key)
      end
    end
  end
end
