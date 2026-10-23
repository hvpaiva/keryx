# frozen_string_literal: true

module Keryx
  module CLI
    module ContextView
      ENDED = '-'
      UNKNOWN = 'unknown'

      module_function

      # A session that ended is not read at all; a live one keryx cannot read is unknown.
      def cell(app, entry)
        return ENDED if entry.ended?

        context = app.meter.read(entry.occupant)
        context ? context.label : [:muted, UNKNOWN]
      end

      def record(app, entry) = entry.ended? ? nil : app.meter.read(entry.occupant)&.record
    end
  end
end
