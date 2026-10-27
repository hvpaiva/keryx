# frozen_string_literal: true

require_relative '../cli/command'
require_relative '../duration'
require_relative 'delivery'

module Keryx
  module Commands
    class Ask < CLI::Command
      define 'ask', section: 'Mail Commands', arguments: 'ADDRESS [TEXT]', min: 1, max: 2,
                    summary: 'Send a request that expects a reply',
                    description: "Send a request that expects a reply.\n\n" \
                                 'The request stays open until the recipient answers it with keryx reply, or ' \
                                 'until you withdraw it with keryx withdraw, and keryx status lists it while it ' \
                                 'waits. --within sets a deadline that status ' \
                                 'reports as overdue once it passes. The reply rings the session that holds the ' \
                                 'address it was sent from, this session unless --as names another, so there is ' \
                                 'no need to wait for it; keryx wait blocks until it comes for the cases that ' \
                                 'cannot go on without it. When no session holds that address, no bell rings and ' \
                                 "the reply waits in its mailbox.\n\n#{ADDRESSING}\n\n" \
                                 'When /etc/keryx/check exists, keryx runs its checker before it writes the ' \
                                 'request; a refusal writes nothing, and keryx prints the reason the checker gives ' \
                                 "and exits 1. A person's messages and keryx's own notices are not checked, and " \
                                 'keryx send --help says more.',
                    examples: [['Ask for a review with a deadline', 'ask rev-1 "Review PR #448" --within 30m'],
                               ['Ask with a longer brief from a file', 'ask impl --file brief.md']]

      def self.follow_up(app, id)
        as = app.as && " --as #{app.me}"
        wait = "'keryx#{as} wait #{id}'"
        unless as || app.caller.agent?
          return "'keryx inbox' shows the reply when it arrives; #{wait} blocks until then."
        end

        occupant = app.store.occupant(app.me)
        if app.bell.reaches?(occupant)
          return "The reply will ring #{holder(app, occupant)}; #{wait} blocks until it arrives."
        end

        "#{nobody(app, occupant)}, so no bell rings for the reply; 'keryx#{as} inbox' shows it when it arrives, and " \
          "#{wait} blocks until then."
      end

      def self.holder(app, occupant)
        app.caller.holds?(occupant) ? 'this session' : "the session that holds #{app.full(app.me)}"
      end

      def self.nobody(app, occupant)
        return "No session holds #{app.full(app.me)}" unless occupant

        "keryx cannot reach the session that holds #{app.full(app.me)}"
      end
      private_class_method :holder, :nobody

      def define_options(parser)
        body_option(parser)
        parser.on('--within DURATION', 'Expect the reply within DURATION, such as 30m or 1h30m') do |duration|
          options[:within] = duration
        end
      end

      def call(arguments)
        posted = app.postman.post(sender: app.me, recipient: app.address(arguments[0]), kind: 'request',
                                  body: body(arguments[1]), due_at:, command: 'ask')
        message = posted.message
        terminal.puts("#{asked(message)} #{Delivery.note(posted)}", Ask.follow_up(app, message.id))
      end

      private

      def asked(message) = "Asked #{message.to} (#{terminal.paint(:id, message.id)})."

      def due_at = options[:within] && (app.now + Duration.parse(options[:within]))
    end
  end
end
