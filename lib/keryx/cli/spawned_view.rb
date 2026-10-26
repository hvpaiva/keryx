# frozen_string_literal: true

module Keryx
  module CLI
    # What spawn recorded about the session it started, as who -o json gives it, with the director as a full address.
    # The record belongs to the address, so the entry of a session address, which reads the same folder, has none.
    module SpawnedView
      HELP = 'spawned is what keryx spawn recorded about the session it started, from just after it opens the pane ' \
             'until a session joins the address, kept when spawn gives up waiting: director (the address spawn ran ' \
             'as), harness, herdr_socket and herdr_pane, so a launcher finds the pane of a session that a dialog ' \
             'stops before its join. It is null when there is none, as on a session address, and when the record ' \
             'cannot be read.'

      module_function

      def record(app, name)
        return if name.include?('/')

        record = app.store.spawned(name)&.record or return
        record.merge('director' => app.full(record['director']))
      end
    end
  end
end
