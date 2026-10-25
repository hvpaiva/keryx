# frozen_string_literal: true

require_relative '../cli/address_view'
require_relative '../cli/command'

module Keryx
  module Commands
    class Whoami < CLI::Command
      define 'whoami', section: 'Session Commands',
                       summary: 'Show the address this session acts as',
                       description: 'Show the address this session acts as and what keryx knows about the ' \
                                    "session.\n\n" \
                                    'An agent session acts as the address it joined. A person at a terminal acts ' \
                                    'as an address named after USER, created on first use, unless --as names ' \
                                    'another.',
                       examples: [['Check which address replies will go to', 'whoami']]

      def define_options(parser) = output_option(parser)

      def call(_arguments)
        name = app.me
        record = app.store.address(name)
        occupant = app.store.occupant(name)
        data = { 'address' => app.full(name), **CLI::AddressView.record(app, name, occupant), 'role' => record&.role,
                 'unread' => app.store.unread(name).size, 'session' => occupant&.record }
        json? ? print_json(data) : show(data, occupant)
        nil
      end

      private

      def show(data, occupant)
        terminal.puts(terminal.paint(:address, data['address']))
        rows = { 'role' => data['role'], 'unread' => data['unread'].to_s }
        rows.merge!(session_rows(data, occupant)) if occupant
        rows.compact.each do |label, value|
          terminal.puts("#{terminal.paint(:muted, label.ljust(8))} #{Text.plain(value)}")
        end
      end

      # A displaced session names the address it came from, and the holder the session address that reaches it alone.
      def session_rows(data, occupant)
        displaced = data['address'] == data['session_address']
        { 'address' => (Address.parse(data['address']).stable.to_s if displaced),
          'reach' => (data['session_address'] unless displaced), 'harness' => occupant.harness,
          'session' => Join.where(occupant), 'joined' => "#{age(occupant.joined_at)} ago" }
      end
    end
  end
end
