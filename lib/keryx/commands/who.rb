# frozen_string_literal: true

require_relative '../cli/command'
require_relative '../cli/table'

module Keryx
  module Commands
    class Who < CLI::Command
      SESSION_ROLES = { 'none' => :muted, 'gone' => :failed, 'blocked' => :deferred, 'unknown' => :muted }.freeze

      define 'who', section: 'Session Commands',
                    summary: 'List the addresses on this machine',
                    description: "List the addresses on this machine and the sessions holding them.\n\n" \
                                 'SESSION is none when no session holds the address, gone when the session ended, ' \
                                 "live when its process runs, or herdr's view of the agent (idle, working, " \
                                 'blocked, done) when herdr sees it in its pane.',
                    examples: [['See who can receive messages', 'who'], ['List addresses for a script', 'who -o json']]

      def define_options(parser) = output_option(parser)

      def call(_arguments)
        entries = app.roster.entries
        return print_json(entries.map { record(it) }) if json?
        return terminal.puts('No addresses yet. A session joins one with: keryx join NAME') if entries.empty?

        terminal.puts(CLI::Table.render(terminal, %w[ADDRESS ROLE HARNESS SESSION UNREAD], entries.map { row(it) }))
      end

      private

      def row(entry)
        [[:address, app.full(entry.name)], entry.role || '-', entry.occupant&.harness || '-',
         [SESSION_ROLES[entry.session], entry.session], unread(entry.unread)]
      end

      def unread(count) = count.positive? ? [:unread, count.to_s] : '0'

      def record(entry)
        { 'address' => app.full(entry.name), 'role' => entry.role, 'harness' => entry.occupant&.harness,
          'session' => entry.session, 'unread' => entry.unread }
      end
    end
  end
end
