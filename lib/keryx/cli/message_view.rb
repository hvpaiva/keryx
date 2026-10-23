# frozen_string_literal: true

require_relative '../duration'
require_relative '../message'
require_relative '../text'

module Keryx
  module CLI
    module MessageView
      LABEL_WIDTH = 9
      TIME_FORMAT = '%Y-%m-%d %H:%M:%S UTC'
      # A message names the request it was sent in the thread of with keryx send --re, which it does not answer.
      IN_REPLY_TO = { 'withdrawal' => 'withdraws', 'message' => 're' }.freeze

      module_function

      def due(message, now)
        return '-' unless message.request? && message.due_at

        left = message.due_at - now
        left.negative? ? "overdue #{Duration.short(-left)}" : "in #{Duration.ahead(left)}"
      end

      def render(terminal, message, now, withdrawal = nil)
        header = fields(message, now, withdrawal).map do |label, value|
          "#{terminal.paint(:muted, label.ljust(LABEL_WIDTH))} #{Text.plain(value)}"
        end
        [*header, '', Text.plain(message.body.chomp, layout: true), *hint(terminal, message, withdrawal)].join("\n")
      end

      def record(message, withdrawal = nil)
        message.request? ? message.record.merge('withdrawn_by' => withdrawal&.id) : message.record
      end

      def fields(message, now, withdrawal = nil)
        rows = [['id', message.id], ['kind', kind(message, now, withdrawal)], ['from', message.from],
                ['to', message.to]]
        rows << ['thread', message.thread] unless message.thread == message.id
        rows << [IN_REPLY_TO.fetch(message.kind, 'reply to'), message.in_reply_to] if message.in_reply_to
        [*rows, *sent(message, now), *withdrawn(withdrawal, now)]
      end

      def kind(message, now, withdrawal)
        message.request? && message.due_at && !withdrawal ? "request, due #{due(message, now)}" : message.kind
      end

      def sent(message, now)
        rows = [['sent', moment(message.created_at, now)]]
        message.context ? [*rows, ['context', "#{message.context.label} when sent"]] : rows
      end

      def withdrawn(withdrawal, now)
        withdrawal ? [['withdrawn', "#{withdrawal.id} at #{moment(withdrawal.created_at, now)}"]] : []
      end

      def moment(time, now) = "#{time.utc.strftime(TIME_FORMAT)} (#{Duration.short(now - time)} ago)"

      def hint(terminal, message, withdrawal = nil)
        return no_reply(terminal, withdrawal) if withdrawal
        return [] unless message.request?

        ['', terminal.paint(:muted, "Answer with: keryx reply #{message.id} TEXT")]
      end

      def no_reply(terminal, withdrawal)
        note = ['', terminal.paint(:muted, 'Its sender withdrew this request, so it needs no reply.')]
        reason = withdrawal.body.strip
        return note if reason == format(Message::WITHDRAWN, id: withdrawal.in_reply_to)

        [*note, "#{terminal.paint(:muted, 'Reason:')} #{Text.plain(reason, layout: true)}"]
      end
    end
  end
end
