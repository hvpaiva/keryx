# frozen_string_literal: true

require_relative '../roster'

module Keryx
  module CLI
    # who and status leave out the addresses nobody holds and nobody writes to, unless asked for all of them.
    ShortView = Data.define(:entries, :hidden, :all)

    class ShortView
      HELP = 'It leaves out the addresses nobody holds and nobody writes to: no session holds them, nothing in their ' \
             'mailbox is unread, and no open request waits on them, sent to them or by them. A retired address is ' \
             "never listed ('keryx retire --help')."

      def self.option(parser, options)
        parser.on('-a', '--all', 'List the addresses with no session, no unread mail and no open request too') do
          options[:all] = true
        end
      end

      # The open requests are looked up only for the short view, which needs them.
      def self.of(entries, all:)
        return new(entries:, hidden: 0, all: true) if all

        waiting = Roster.waiting_on(yield)
        shown = entries.reject { it.quiet?(waiting) }
        new(entries: shown, hidden: entries.size - shown.size, all: false)
      end

      def name = all ? 'all' : 'short'

      def note(command)
        return if hidden.zero?

        one = hidden == 1
        "#{hidden} #{one ? 'address' : 'addresses'} with no session, no unread mail and no open request " \
          "#{one ? 'is' : 'are'} hidden; 'keryx #{command} --all' lists #{one ? 'it' : 'them'}."
      end
    end
  end
end
