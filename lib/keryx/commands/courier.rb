# frozen_string_literal: true

require_relative '../cli/command'
require_relative '../duration'
require_relative '../forwarder'

module Keryx
  module Commands
    class Courier < CLI::Command
      DEFAULT_INTERVAL = '30s'

      define 'courier', section: 'Overview Commands',
                        summary: 'Forward queued mail, ring again and report missed deadlines',
                        description: 'Do on a schedule what no single command can. Each round forwards the ' \
                                     'messages queued for another machine, rings again for unread messages whose ' \
                                     'bell did not reach a session, and tells the sender of a request whose ' \
                                     "deadline passed without a reply.\n\n" \
                                     'It also reads the context of each session that has a ceiling (keryx join ' \
                                     '--help) and tells the session and its director to reach a stopping point, ' \
                                     'once when the context reaches 80% of the ceiling and once when it reaches ' \
                                     'the ceiling. The notice rings the session like any message: a Claude Code ' \
                                     'session gets it when the bell rings and a Codex session after its next tool ' \
                                     'call, and keryx types it into a working Cursor session, which queues it ' \
                                     "until its turn ends.\n\n" \
                                     'It reads the herdr pane of each running session that keryx spawn recorded a ' \
                                     'director for, other than its own address, and when the pane shows a dialog, ' \
                                     'such as a permission or folder trust question, it sends the director a ' \
                                     'message with the pane and the dialog\'s text. Each dialog is told once; a new ' \
                                     'one in the same pane is told again, and so is the same one once a read showed ' \
                                     'the pane without it. A moved selection or a countdown makes no new dialog, ' \
                                     'and a menu that says no action is required is not told. keryx never answers ' \
                                     "a dialog. keryx who shows the director of each session.\n\n" \
                                     'Run it on each machine as a user service, so mail for a machine that was ' \
                                     'asleep or off the network goes out when it is back. It prints one line for ' \
                                     "each thing it does, the config file's warnings before its first round, and " \
                                     'each problem it finds in the mailboxes once, after the round that found it.',
                        examples: [['Run one round', 'courier --once'],
                                   ['Run as a service, every minute', 'courier --interval 1m']]

      def define_options(parser)
        parser.on('--once', 'Run one round and exit') { options[:once] = true }
        parser.on('--interval DURATION', "Wait DURATION between rounds (default #{DEFAULT_INTERVAL})") do |interval|
          options[:interval] = interval
        end
      end

      def call(_arguments)
        interval = Duration.parse(options[:interval] || DEFAULT_INTERVAL)
        courier = app.courier
        warn_problems
        waiting = {}
        loop do
          report(courier.round, waiting)
          app.signal_changes
          warn_problems
          return nil if options[:once]

          app.sleeper.call(interval)
        end
      end

      private

      def report(round, waiting)
        round.forwarded.each { |host, results| report_host(host, results, waiting) }
        round.rung.each { |name, bell| say("rang #{app.full(name)}: #{bell.status} #{bell.detail}".strip) }
        round.overdue.each { say("told #{it.from} that #{it.id} to #{it.to} is past its deadline") }
        report_notices(round)
        round.errors.each { say(it) }
      end

      def report_notices(round)
        round.context.each { say(context_line(it)) }
        round.dialogs.each { say(dialog_line(it)) }
      end

      def report_host(host, results, waiting)
        results.each do |id, result|
          case result.status
          when Forwarder::FORWARDED then say("forwarded #{id} to #{host}")
          when Forwarder::REFUSED then say("#{host} refused #{id}: #{result.detail}")
          end
        end
        queued = results.values.select { it.status == Forwarder::QUEUED }
        line = queued.empty? ? nil : "#{queued.size} message(s) wait for #{host}: #{queued.first.detail}"
        say(line) if line && waiting[host] != line
        waiting[host] = line
      end

      def dialog_line(told)
        "told #{told.recipient} that #{app.full(told.name)} stops at a dialog in pane #{told.pane}"
      end

      def context_line(notice)
        "told #{notice.recipient} that #{app.full(notice.name)} is at #{notice.context.against(notice.ceiling)}, " \
          "#{'near ' if notice.stage == :near}its context ceiling"
      end

      def say(line) = terminal.puts(Text.plain(line))

      def warn_problems = app.take_problems.each { terminal.warning(it) }
    end
  end
end
