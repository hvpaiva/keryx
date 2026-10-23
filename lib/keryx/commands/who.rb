# frozen_string_literal: true

require_relative '../cli/command'
require_relative '../cli/context_view'
require_relative '../cli/short_view'
require_relative '../cli/table'

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

      define 'who', section: 'Session Commands',
                    summary: 'List the addresses on this machine',
                    description: "List the addresses on this machine and the sessions holding them.\n\n" \
                                 "#{CLI::ShortView::HELP} The last line says how many it left out, and --all " \
                                 'lists every address. With -o json, view says which list it is, short or all, and ' \
                                 "hidden how many addresses it left out.\n\n" \
                                 'SESSION is none when no session holds the address, gone when the session ended, ' \
                                 "live when its process runs, or herdr's view of the agent (idle, working, " \
                                 "blocked, done) when herdr sees it in its pane.\n\n" \
                                 "#{CONTEXT}",
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
        return terminal.puts('No addresses yet. A session joins one with: keryx join NAME') if entries.empty?

        print_table(view.entries)
        view.note('who')&.then { terminal.puts(terminal.paint(:muted, it)) }
      end

      private

      def print_table(entries)
        return if entries.empty?

        terminal.puts(CLI::Table.render(terminal, %w[ADDRESS ROLE HARNESS SESSION CONTEXT UNREAD],
                                        entries.map { row(it) }))
      end

      def json(view) = { 'view' => view.name, 'hidden' => view.hidden, 'addresses' => view.entries.map { record(it) } }

      def row(entry)
        [[:address, app.full(entry.name)], entry.role || '-', entry.occupant&.harness || '-',
         [SESSION_ROLES[entry.session], entry.session], CLI::ContextView.cell(app, entry), unread(entry.unread)]
      end

      def unread(count) = count.positive? ? [:unread, count.to_s] : '0'

      def record(entry)
        { 'address' => app.full(entry.name), 'role' => entry.role, 'harness' => entry.occupant&.harness,
          'session' => entry.session, 'context' => CLI::ContextView.record(app, entry),
          'ceiling' => entry.occupant&.ceiling, 'unread' => entry.unread }
      end
    end
  end
end
