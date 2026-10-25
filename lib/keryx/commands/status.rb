# frozen_string_literal: true

require_relative '../cli/activity_view'
require_relative '../cli/address_view'
require_relative '../cli/command'
require_relative '../cli/context_view'
require_relative '../cli/message_view'
require_relative '../cli/short_view'
require_relative '../cli/table'

module Keryx
  module Commands
    class Status < CLI::Command
      Unrung = Data.define(:message, :status, :detail)

      define 'status', section: 'Overview Commands',
                       summary: 'Show what is pending on this machine',
                       description: 'Show what is pending on this machine, for a person keeping an eye on the ' \
                                    "sessions.\n\n" \
                                    'ADDRESSES lists each address with its session, its ACTIVE time and the context ' \
                                    'it uses, as keryx who shows them, its unread messages and the requests ' \
                                    'waiting for its answer, a taken one included. It leaves out the addresses ' \
                                    'keryx who leaves out and says how many, unless --all is given, and with -o ' \
                                    'json view and hidden say the same. ACTIVE is how long ago the harness last ' \
                                    'wrote its own record of the session, the file keryx who names, so a session ' \
                                    'on a long tool call looks quiet; it is not a liveness check. ' \
                                    'OPEN REQUESTS lists every request its ' \
                                    'recipient has not replied to yet and its sender has not withdrawn, with its ' \
                                    'deadline, including those sent to another machine. Its STATE is unread or ' \
                                    'read, queued or forwarded for one sent to another machine, and taken once its ' \
                                    'recipient wrote in its thread with keryx send --re, which keeps it open until ' \
                                    'the reply. ' \
                                    'NOT RUNG lists unread messages whose bell did not reach a session, and why; ' \
                                    'keryx ring tries those again. NOT FORWARDED lists messages for another ' \
                                    'machine that are still queued or that it refused; keryx courier forwards the ' \
                                    'queued ones.',
                       examples: [['Check whether anything is stuck', 'status'], ['Feed a script', 'status -o json']]

      def define_options(parser)
        CLI::ShortView.option(parser, options)
        output_option(parser)
      end

      def call(_arguments)
        roster = app.roster
        entries = roster.entries
        requests = roster.open_requests
        view = CLI::ShortView.of(entries, all: options[:all]) { requests }
        unrung = not_rung
        outgoing = not_forwarded
        report_damaged_claims
        return print_json(json(view, requests, unrung, outgoing)) if json?
        return terminal.puts('No addresses yet. A session joins one with: keryx join MEMBER.TEAM') if entries.empty?

        print_sections(view, requests, unrung, outgoing)
      end

      private

      def print_sections(view, requests, unrung, outgoing)
        waiting = requests.map(&:first).tally
        section('ADDRESSES', %w[ADDRESS ROLE SESSION ACTIVE CONTEXT UNREAD WAITING],
                view.entries.map { address_row(it, waiting) })
        view.note('status')&.then { terminal.puts(terminal.paint(:muted, it)) }
        section('OPEN REQUESTS', %w[ID FROM TO AGE DUE STATE SUMMARY], requests.map { request_row(it.last) })
        section('NOT RUNG', %w[ID TO FROM BELL DETAIL], unrung.map { unrung_row(it) })
        section('NOT FORWARDED', %w[ID TO FROM STATE ATTEMPTS DETAIL], outgoing.map { forward_row(*it) })
      end

      def not_rung
        app.store.current_names.flat_map do |name|
          app.store.unread(name).filter_map do |message|
            bell = app.store.receipt(name, message.id, 'bell') || { 'status' => 'none', 'detail' => 'never rung' }
            Unrung.new(message, bell['status'], bell['detail']) unless bell['status'] == Bell::RUNG
          end
        end
      end

      # A damaged claim is shown on every look until a courier writes over it or someone removes it.
      def report_damaged_claims
        app.store.current_names.each do |name|
          app.store.report_damaged_claims(name, Keryx::Courier::CONTEXT_CLAIM) { Ulid.valid?(it) }
        end
      end

      def not_forwarded
        app.store.outbox.outgoing.reject { it.state == :forwarded }.map do |outgoing|
          [outgoing, app.store.outbox.receipt(outgoing.host, outgoing.message.id) || {}]
        end
      end

      def json(view, requests, unrung, outgoing)
        waiting = requests.map(&:first).tally
        { 'view' => view.name, 'hidden' => view.hidden,
          'addresses' => view.entries.map { address_record(it, waiting) },
          'open_requests' => requests.map { request_record(it.last) },
          'not_rung' => unrung.map { unrung_record(it) },
          'not_forwarded' => outgoing.map { forward_record(*it) } }
      end

      def forward_record(outgoing, receipt)
        { 'id' => outgoing.message.id, 'to' => outgoing.message.to, 'from' => outgoing.message.from,
          'state' => outgoing.state.to_s, 'attempts' => receipt.fetch('attempts', 0), 'detail' => receipt['detail'] }
      end

      def forward_row(outgoing, receipt)
        message = outgoing.message
        [[:id, message.id], message.to, message.from, [outgoing.state, outgoing.state.to_s],
         receipt.fetch('attempts', 0).to_s, Text.plain(receipt['detail'].to_s)]
      end

      def address_record(entry, waiting)
        { 'address' => app.full(entry.name), **CLI::AddressView.record(app, entry.name, entry.occupant),
          'role' => entry.role, 'session' => entry.session, 'last_activity' => CLI::ActivityView.record(app, entry),
          'context' => CLI::ContextView.record(app, entry), 'ceiling' => entry.occupant&.ceiling,
          'unread' => entry.unread, 'waiting' => waiting.fetch(entry.name, 0) }
      end

      def request_record(stored)
        stored.message.record.merge('state' => stored.state.to_s, 'overdue' => stored.message.overdue?(app.now))
      end

      def unrung_record(unrung)
        { 'id' => unrung.message.id, 'to' => unrung.message.to, 'from' => unrung.message.from,
          'bell' => unrung.status, 'detail' => unrung.detail }
      end

      def section(title, headers, rows)
        terminal.puts('') unless title == 'ADDRESSES'
        terminal.puts(terminal.paint(:header, title))
        terminal.puts(rows.empty? ? terminal.paint(:muted, 'none') : CLI::Table.render(terminal, headers, rows))
      end

      def address_row(entry, waiting)
        count = waiting.fetch(entry.name, 0)
        [[:address, app.full(entry.name)], entry.role || '-', entry.session, CLI::ActivityView.cell(app, entry),
         CLI::ContextView.cell(app, entry), entry.unread.positive? ? [:unread, entry.unread.to_s] : '0',
         count.positive? ? [:request, count.to_s] : '0']
      end

      def request_row(stored)
        message = stored.message
        due = CLI::MessageView.due(message, app.now)
        [[:id, message.id], message.from, message.to, age(message.created_at),
         message.overdue?(app.now) ? [:overdue, due] : due, [stored.state, stored.state.to_s], message.summary]
      end

      def unrung_row(unrung)
        [[:id, unrung.message.id], unrung.message.to, unrung.message.from,
         [unrung.status == 'none' ? :muted : unrung.status.to_sym, unrung.status], Text.plain(unrung.detail.to_s)]
      end
    end
  end
end
