# frozen_string_literal: true

module Keryx
  module CLI
    # The join of the session holding an address, as who -o json gives it, with its times spelled as the session record
    # keeps them. The Claude Code socket stays out, and so do the ceiling and the session address, which the address's
    # own fields give.
    module JoinView
      FIELDS = %w[harness session_id pid started cwd transcript herdr_socket herdr_pane joined_at].freeze
      HELP = 'join is the session the entry lists, the holder or a session join --force displaced, or null when ' \
             'none: harness, session_id, pid, started, cwd, transcript, herdr_socket, herdr_pane and joined_at, the ' \
             'time it joined in ISO 8601 UTC with nine digits of fraction.'

      module_function

      def record(occupant) = occupant&.record&.slice(*FIELDS)
    end
  end
end
