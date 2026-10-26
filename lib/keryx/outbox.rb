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
    THREAD_LOCK = 'thread.lock'

    def initialize(root, problems: [], clock: -> { Time.now.utc })
      @base = File.join(root, DIR)
      @problems = problems
      @clock = clock
    end

    def queue(host, message)
      make_dirs(dir(host), ['tmp', 'receipts', *STATES.values])
      return :duplicate if STATES.values.any? { File.exist?(File.join(dir(host), it, "#{message.id}.json")) }

      drop_in(dir(host), 'new', message)
    end

    # Messages of one thread written for HOST take turns. The block gets the id of the last message of THREAD still
    # waiting in new/, the queue the forwarder sends in id order, and returns the message to queue in the same hold.
    # A message that left new/ arrived or was refused, so the next one goes after it whatever its id. Such a message can
    # hold the id the block chose; a taken id is given to the block to choose after, so the message returned was queued.
    def queue_in_thread(host, thread)
      make_dirs(dir(host), ['tmp', 'receipts', *STATES.values])
      File.open(File.join(dir(host), THREAD_LOCK), File::RDWR | File::CREAT, FILE_MODE) do |lock|
        lock.flock(File::LOCK_EX)
        message = yield(queued(host).select { it.thread == thread }.map(&:id).max)
        message = yield(message.id) while queue(host, message) == :duplicate
        message
      end
    end

    def hosts
      return [] unless File.directory?(@base)

      Dir.children(@base).select { Address::HOST.match?(it) && File.directory?(File.join(@base, it)) }.sort
    end

    def outgoing(hosts = self.hosts)
      found = Array(hosts).flat_map do |host|
        STATES.flat_map do |state, folder|
          messages = state == :queued ? queued(host) : messages_in(File.join(dir(host), folder))
          messages.map { OutgoingMessage.new(host, it, state) }
        end
      end
      found.sort_by { it.message.id }
    end

    # What new/ holds for HOST that this keryx still sends. A message from before team names, of format 1 or with an
    # address that has no team, moves to refused/ with its reason the first time it is read, so it holds back no
    # thread, and the command that moves it reports it once.
    def queued(host)
      folder = File.join(dir(host), STATES.fetch(:queued))
      ids_in(folder).filter_map do |id|
        reason, message = old(File.join(folder, "#{id}.json"))
        reason ? refuse_old(host, id, reason) : message
      end
    end

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

    # A file of format 1, from before team names, no longer parses, and cur/ and refused/ skip it quietly.
    def skipped(path, error) = error.is_a?(Message::OldFormat) ? nil : super

    # Why the message at PATH is from before team names, or else nil and the message, which is nil too when the file
    # cannot be read.
    def old(path)
      message = load_message(path)
      teamless = message.teamless
      teamless ? [format(Address::TEAMLESS, teamless)] : [nil, message]
    rescue Message::OldFormat => e
      [e.message]
    rescue Errno::ENOENT
      nil
    rescue Error => e
      skipped(path, e)
      nil
    end

    # The outcome comes first, as the forwarder writes it, and a decision taken before stays. Nothing is sent.
    def refuse_old(host, id, reason)
      write_outcome(host, id, { 'status' => 'refused', 'detail' => reason, 'at' => @clock.call.utc.iso8601 })
      state = outcome(host, id)&.fetch('status') || 'refused'
      if settle(host, id, state.to_sym) && state == 'refused'
        @problems << "moved #{File.join(dir(host), 'new', "#{id}.json")} to refused/: #{reason}"
      end
      nil
    end

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
