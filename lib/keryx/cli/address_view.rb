# frozen_string_literal: true

require_relative '../address'

module Keryx
  module CLI
    # The fields -o json gives beside an address's full spelling. A holder's session address reaches it alone; a
    # displaced session's is the address it acts as.
    module AddressView
      module_function

      def record(app, name, occupant)
        address = Address.from_name(name, host: app.host)
        session = occupant&.session
        { 'member' => address.member, 'team' => address.team, 'host' => address.host,
          'session_address' => (address.with(session:).to_s if session) }
      end
    end
  end
end
