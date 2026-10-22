# frozen_string_literal: true

require_relative '../duration'
require_relative '../text'

module Keryx
  module CLI
    module MessageView
      LABEL_WIDTH = 9
      TIME_FORMAT = '%Y-%m-%d %H:%M:%S UTC'

      module_function

      def due(message, now)
        return '-' unless message.request? && message.due_at

        left = message.due_at - now
        left.negative? ? "overdue #{Duration.short(-left)}" : "in #{Duration.short(left)}"
      end

      def render(terminal, message, now)
        header = fields(message, now).map do |label, value|
          "#{terminal.paint(:muted, label.ljust(LABEL_WIDTH))} #{value}"
        end
        [*header, '', Text.plain(message.body.chomp, layout: true), *hint(terminal, message)].join("\n")
      end

      def fields(message, now)
        kind = message.request? && message.due_at ? "request, due #{due(message, now)}" : message.kind
        rows = [['id', message.id], ['kind', kind], ['from', message.from], ['to', message.to]]
        rows << ['thread', message.thread] unless message.thread == message.id
        rows << ['reply to', message.in_reply_to] if message.in_reply_to
        sent = message.created_at
        rows << ['sent', "#{sent.utc.strftime(TIME_FORMAT)} (#{Duration.short(now - sent)} ago)"]
      end

      def hint(terminal, message)
        return [] unless message.request?

        ['', terminal.paint(:muted, "Answer with: keryx reply #{message.id} TEXT")]
      end
    end
  end
end
