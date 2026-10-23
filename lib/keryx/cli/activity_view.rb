# frozen_string_literal: true

require_relative '../duration'

module Keryx
  module CLI
    module ActivityView
      ENDED = '-'
      UNKNOWN = 'unknown'

      module_function

      # A session that ended is not read at all, as for its context; a time ahead of the clock reads as 0s ago.
      def cell(app, entry)
        return ENDED if entry.ended?

        time = app.meter.activity(entry.occupant) or return [:muted, UNKNOWN]
        "#{Duration.short(app.now - time)} ago"
      end

      def record(app, entry) = entry.ended? ? nil : app.meter.activity(entry.occupant)&.utc&.iso8601
    end
  end
end
