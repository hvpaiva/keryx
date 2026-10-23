# frozen_string_literal: true

require_relative 'address'
require_relative 'error'
require_relative 'files'

module Keryx
  OutgoingMessage = Data.define(:host, :message, :state)

  class Outbox
    include Files

    DIR = 'outbox'
    STATES = { queued: 'new', forwarded: 'cur', refused: 'refused' }.freeze
    DECISIONS = %w[forwarded refused].freeze
    LOCK = 'outcomes.lock'

    def initialize(root, problems: [])
      @base = File.join(root, DIR)
      @problems = problems
    end

    def queue(host, message)
      make_dirs(dir(host), ['tmp', 'receipts', *STATES.values])
      return :duplicate if STATES.values.any? { File.exist?(File.join(dir(host), it, "#{message.id}.json")) }

      drop_in(dir(host), 'new', message)
    end

    def hosts
      return [] unless File.directory?(@base)

      Dir.children(@base).select { Address::HOST.match?(it) && File.directory?(File.join(@base, it)) }.sort
    end

    def outgoing(hosts = self.hosts)
      found = Array(hosts).flat_map do |host|
        STATES.flat_map do |state, folder|
          messages_in(File.join(dir(host), folder)).map { OutgoingMessage.new(host, it, state) }
        end
      end
      found.sort_by { it.message.id }
    end

    def queued(host) = messages_in(File.join(dir(host), STATES.fetch(:queued)))

    def settle(host, id, state)
      target = File.join(dir(host), STATES.fetch(state))
      File.rename(File.join(dir(host), 'new', "#{id}.json"), File.join(target, "#{id}.json"))
      [target, File.join(dir(host), 'new')].each { sync_directory(it) }
      true
    rescue Errno::ENOENT
      false
    end

    def discard(host, id)
      STATES.each_value { FileUtils.rm_f(File.join(dir(host), it, "#{id}.json")) }
      [receipt_file(host, id), outcome_file(host, id)].each { FileUtils.rm_f(it) }
    end

    def write_receipt(host, id, data) = write_atomic(receipt_file(host, id), JSON.generate(data))

    # The first decision stays, so an attempt that fails after another one settled the message cannot undo it.
    def write_outcome(host, id, data)
      return if write_once(outcome_file(host, id), JSON.generate(data)) == :delivered || outcome(host, id)

      replace_undecided(host, id, data)
    end

    # A decision is never written again, so a field of the wrong type is left out rather than costing the decision.
    def outcome(host, id)
      path = outcome_file(host, id)
      data = read_json(path) or return nil
      raise Error, "#{path} has a bad status" unless DECISIONS.include?(data['status'])

      bad = Files.bad_options(data)
      bad.each { @problems << "#{path} has a bad #{it}; keryx reads the outcome without it" }
      data.except(*bad)
    rescue Error => e
      @problems << "#{e.message}; it is ignored until keryx writes it again"
      nil
    end

    def receipt(host, id) = outcome(host, id) || read_receipt(receipt_file(host, id))

    private

    def dir(host)
      raise Error, "invalid host #{host.inspect}" unless Address::HOST.match?(host.to_s)

      File.join(@base, host)
    end

    # Attempts that both found no decision take turns, and the second keeps what the first wrote.
    def replace_undecided(host, id, data)
      File.open(File.join(dir(host), LOCK), File::RDWR | File::CREAT, FILE_MODE) do |lock|
        lock.flock(File::LOCK_EX)
        write_atomic(outcome_file(host, id), JSON.generate(data)) unless outcome(host, id)
      end
    end

    def receipt_file(host, id) = File.join(dir(host), 'receipts', "#{id}.forward")

    def outcome_file(host, id) = File.join(dir(host), 'receipts', "#{id}.outcome")
  end
end
