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
                                     'Run it on each machine as a user service, so mail for a machine that was ' \
                                     'asleep or off the network goes out when it is back. It prints one line for ' \
                                     "each thing it does, and the config file's warnings before its first round.",
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
        app.take_problems.each { terminal.warning(it) }
        waiting = {}
        loop do
          report(courier.round, waiting)
          return nil if options[:once]

          app.sleeper.call(interval)
        end
      end

      private

      def report(round, waiting)
        round.forwarded.each { |host, results| report_host(host, results, waiting) }
        round.rung.each { |name, bell| say("rang #{app.full(name)}: #{bell.status} #{bell.detail}".strip) }
        round.overdue.each { say("told #{it.from} that #{it.id} to #{it.to} is past its deadline") }
        round.errors.each { say(it) }
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

      def say(line) = terminal.puts(Text.plain(line))
    end
  end
end
