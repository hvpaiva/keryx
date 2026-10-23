# frozen_string_literal: true

require_relative '../cli/command'

module Keryx
  module Commands
    class Ring < CLI::Command
      define 'ring', section: 'Overview Commands', arguments: '[ADDRESS...]', max: nil,
                     summary: 'Ring again for unread messages',
                     description: 'Ring the bell again for every address with unread messages, or only for the ' \
                                  "addresses given.\n\n" \
                                  'Use it after a bell was deferred or failed, as keryx status reports, once the ' \
                                  'session is free again. Each address gets one bell that counts its unread ' \
                                  'messages.',
                     examples: [['Retry every pending bell', 'ring'], ['Retry one address', 'ring rev-1']]

      def call(arguments)
        names = arguments.empty? ? app.store.address_names : arguments.map { local_name(it) }
        waiting = names.filter_map { ring(it) }
        terminal.puts('Nothing to ring: no address has unread messages.') if waiting.empty?
        nil
      end

      private

      def local_name(text)
        address = app.address(text)
        raise Error, "#{address} is on another machine" unless address.local?(app.host)
        raise Error, "no address #{address}" unless app.store.address?(address.name)

        address.name
      end

      def ring(name)
        unread = app.store.unread(name)
        return if unread.empty?

        result = app.store.reporting { app.bell.ring(name, unread) }
        terminal.puts("#{terminal.paint(:address, app.full(name))}   #{unread.size} unread   #{outcome(result)}")
        unread
      end

      # The bell reads the occupant before anything else, so one it cannot read rings nothing, and its file is reported.
      def outcome(result)
        return terminal.paint(:failed, 'not rung') unless result

        channel = result.channel ? " via #{result.channel}" : ''
        detail = result.detail ? " (#{Text.plain(result.detail)})" : ''
        "#{terminal.paint(result.status.to_sym, result.status)}#{channel}#{detail}"
      end
    end
  end
end
