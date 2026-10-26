# frozen_string_literal: true

require_relative '../duration'
require_relative 'message_view'
require_relative 'table'

module Keryx
  module CLI
    # The rows and records of a mailbox, as keryx inbox lists the one it acts as and keryx history a retired one.
    # WITHDRAWN holds, by id, the withdrawal of each request its sender withdrew.
    module MailboxView
      module_function

      def records(stored, withdrawn) = stored.map { record(it, withdrawn[it.message.id]) }

      def table(terminal, stored, withdrawn, now, state:)
        Table.render(terminal, headers(state:), stored.map { row(it, withdrawn[it.message.id], now, state:) })
      end

      def headers(state:) = %w[ID KIND FROM AGE DUE] + (state ? ['STATE'] : []) + ['SUMMARY']

      def record(stored, withdrawal)
        MessageView.record(stored.message, withdrawal).merge('state' => stored.state.to_s)
      end

      def row(stored, withdrawal, now, state:)
        message = stored.message
        cells = [[:id, message.id], message.request? ? [:request, message.kind] : message.kind, message.from,
                 Duration.short(now - message.created_at), due(message, withdrawal, now)]
        cells << [stored.state, stored.state.to_s] if state
        cells << message.summary
      end

      def due(message, withdrawal, now)
        return [:muted, 'withdrawn'] if withdrawal

        due = MessageView.due(message, now)
        due.start_with?('overdue') ? [:overdue, due] : due
      end
    end
  end
end
