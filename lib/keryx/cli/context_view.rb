# frozen_string_literal: true

module Keryx
  module CLI
    module ContextView
      ENDED = '-'
      UNKNOWN = 'unknown'

      module_function

      STAGES = { near: :deferred, ceiling: :failed }.freeze

      # A session that ended is not read at all; a live one keryx cannot read is unknown. Against a ceiling the share
      # shown is the ceiling's, which is what someone acts on, and the window stays in the JSON output.
      def cell(app, entry)
        return ENDED if entry.ended?

        context = app.meter.read(entry.occupant) or return [:muted, UNKNOWN]
        ceiling = entry.occupant.ceiling or return context.label

        [STAGES[context.stage(ceiling)], context.against(ceiling)]
      end

      def record(app, entry) = entry.ended? ? nil : app.meter.read(entry.occupant)&.record
    end
  end
end
