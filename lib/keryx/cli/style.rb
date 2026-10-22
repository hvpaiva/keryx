# frozen_string_literal: true

module Keryx
  module CLI
    class Style
      MODES = %w[auto always never].freeze
      ROLES = {
        header: '1', id: '33', address: '36', unread: '32', read: '90', request: '35', overdue: '31',
        rung: '32', deferred: '33', failed: '31', absent: '90', muted: '90', error: '31', warning: '33',
        command: '32', flag: '36', comment: '90;3'
      }.freeze

      def self.for(mode, tty:, env:)
        new(enabled: enabled?(mode, tty:, env:))
      end

      def self.enabled?(mode, tty:, env:)
        case mode
        when 'always' then true
        when 'never' then false
        else
          return false if set?(env['NO_COLOR'])
          return true if set?(env['FORCE_COLOR']) || set?(env['CLICOLOR_FORCE'])

          env['TERM'] != 'dumb' && tty
        end
      end

      def self.set?(value) = !value.to_s.empty?
      private_class_method :enabled?, :set?

      def initialize(enabled:)
        @enabled = enabled
      end

      def enabled? = @enabled

      def paint(role, text)
        return text.to_s unless @enabled

        "\e[#{ROLES.fetch(role)}m#{text}\e[0m"
      end
    end
  end
end
