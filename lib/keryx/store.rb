# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'
require_relative 'address'
require_relative 'error'
require_relative 'files'
require_relative 'message'
require_relative 'occupant'
require_relative 'outbox'
require_relative 'incarnations'
require_relative 'retirement'
require_relative 'spawned_records'

module Keryx
  # The record names its member and team apart.
  AddressRecord = Data.define(:member, :team, :role, :created_at) do
    def self.from_record(data)
      member, team, role = data.values_at('member', 'team', 'role')
      raise TypeError, 'a name is not text' unless [member, team].all?(String)
      raise TypeError, 'the role is not text' unless role.nil? || role.is_a?(String)

      new(member:, team:, role:, created_at: Time.iso8601(data['created_at'].to_s))
    end

    def name = "#{member}.#{team}"

    def record = { 'member' => member, 'team' => team, 'role' => role, 'created_at' => created_at.utc.iso8601 }
  end
  StoredMessage = Data.define(:message, :state)

  class Store
    include Files
    include Incarnations
    include Retirement
    include SpawnedRecords

    class Busy < Error; end
    class Damaged < Error; end

    ADDRESSES = 'addresses'
    MAIL = 'mail'
    READ = 'read'
    BOX_DIRS = ['tmp', MAIL, READ, 'receipts'].freeze
    MINIMUM_PREFIX = 4
    OCCUPANTS_LOCK = 'occupants.lock'
    # Above the 10 s Runner gives the herdr call a holder may make while it checks an address.
    LOCK_SECONDS = 15
    LOCK_POLL_SECONDS = 0.05

    attr_reader :root, :problems

    # The local name that sent REQUEST from here, under whatever name the machine had then: only this machine writes
    # its outbox, and nothing that arrives from another machine has the host of its recipient.
    def self.sender_here(holder, request)
      sender = Address.parse(request.from)
      sender.key if holder.nil? || sender.host == Address.parse(request.to).host
    end

    def self.reference(text)
      reference = text.to_s.upcase
      return reference if reference.size >= MINIMUM_PREFIX

      raise Error, "message id #{reference.inspect} is too short; give at least #{MINIMUM_PREFIX} characters"
    end

    # By id, each request among MESSAGES that its own sender withdrew with one of HELD, with that withdrawal.
    def self.withdrawn(messages, held)
      pulled = held.select(&:withdrawal?).group_by(&:in_reply_to)
      messages.select(&:request?).to_h { |request| [request.id, pulled[request.id]&.find { it.withdraws?(request) }] }
              .compact
    end

    def initialize(root, clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep(seconds) })
      @root = root
      @problems = []
      @clock = clock
      @sleeper = sleeper
    end

    def address_names
      base = File.join(root, ADDRESSES)
      return [] unless File.directory?(base)

      Dir.children(base).select { Address.key?(it) && File.file?(address_file(it)) }.sort
    end

    def address?(name) = File.file?(address_file(name))

    def address(name)
      data = read_json(address_file(name)) or return nil
      AddressRecord.from_record(data)
    rescue ArgumentError, KeyError, TypeError, NotAnObject
      raise Error, "#{address_file(name)} is damaged"
    end

    # None starts here in the scope of keryx's own services.
    def create_address(name, role: nil, now: Time.now.utc)
      address = Address.from_key(name, host: nil)
      current = address(name)
      check_new(address) unless current
      BOX_DIRS.each { FileUtils.mkdir_p(File.join(box(name), it), mode: DIR_MODE) }
      return current if current && (role.nil? || role == current.role)

      record = current&.with(role:) || AddressRecord.new(member: address.member, team: address.team, role:,
                                                         created_at: now)
      write_atomic(address_file(name), JSON.generate(record.record.compact))
      record
    end

    # NAME is an address's key, or KEY/SESSION for one of its incarnations; see Incarnations.
    def occupant(name)
      path = occupant_path(name)
      data = read_json(path) or return nil
      Occupant.from_record(data)
    rescue ArgumentError, KeyError, TypeError, NotAnObject
      raise Error, "#{path} is damaged"
    end

    # A command that walks every address goes on past a file it cannot read: the file is reported once as a problem,
    # and the fallback stands for what the block would have read.
    def reporting(fallback = nil)
      yield
    rescue Error => e
      @problems << e.message
      fallback
    end

    def bind(name, occupant)
      require_address(name)
      write_atomic(occupant_path(name), JSON.generate(occupant.record))
    end

    def unbind(name) = FileUtils.rm_f(occupant_path(name))

    # Changes to who holds which address take turns across processes; the kernel drops the lock with the process.
    def with_occupants_lock(within: LOCK_SECONDS)
      FileUtils.mkdir_p(root, mode: DIR_MODE)
      File.open(File.join(root, OCCUPANTS_LOCK), File::RDWR | File::CREAT, FILE_MODE) do |file|
        take(file, within)
        yield
      end
    end

    def deliver(name, message)
      require_address(name)
      make_dirs(box(name), BOX_DIRS)
      drop_in(box(name), MAIL, message)
    end

    # Every message the address holds, whichever of its incarnations it was sent to.
    def stored(name)
      read = read_ids(name)
      messages_in(File.join(box(name), MAIL)).map { StoredMessage.new(it, read.include?(it.id) ? :read : :unread) }
    end

    # What the incarnation NAME lists; see Incarnations#sees.
    def mailbox(name) = sees(name).then { |seen| stored(name).select { seen.call(it.message) } }

    def unread(name)
      read = read_ids(name)
      messages_in(File.join(box(name), MAIL)) { !read.include?(it) }.select(&sees(name))
    end

    # By id, each request among MESSAGES that its own sender withdrew in the mailbox of NAME, with that withdrawal.
    def withdrawals(name, messages)
      return {} if messages.none?(&:request?)

      Store.withdrawn(messages, messages_in(File.join(box(name), MAIL)))
    end

    def find(name, reference)
      reference = Store.reference(reference)
      found = messages_in(File.join(box(name), MAIL)) { it.start_with?(reference) }.select(&sees(name, by_id: true))
      ids = found.map(&:id)
      raise Error, "#{reference} matches #{ids.size} messages (#{ids.join(', ')}); type more of the id" if ids.size > 1

      message = found.first or raise Error, "no message #{reference} in the mailbox of #{name}"
      StoredMessage.new(message, read_ids(name).include?(message.id) ? :read : :unread)
    end

    def mark_read(name, id)
      make_dirs(box(name), [READ])
      link(File.join(box(name), MAIL, "#{id}.json"), File.join(box(name), READ, "#{id}.json")) == :delivered
    rescue Errno::ENOENT
      raise Error, "no message #{id} in the mailbox of #{name}"
    end

    def outbox = @outbox ||= Outbox.new(root, problems: @problems, clock: @clock)

    def all_messages
      kept = address_names.flat_map { |name| stored(name).map { [name, it] } }
      sent = outbox.outgoing.reject { it.state == :refused }.map { [nil, StoredMessage.new(it.message, it.state)] }
      kept + sent
    end

    def write_receipt(name, id, kind, data)
      write_atomic(receipt_file(name, id, kind), JSON.generate(data))
    end

    def receipt(name, id, kind) = read_receipt(receipt_file(name, id, kind))

    def marked?(name, id, kind) = File.exist?(receipt_file(name, id, kind))

    def mark_once(name, id, kind)
      File.open(receipt_file(name, id, kind), File::WRONLY | File::CREAT | File::EXCL, FILE_MODE) { true }
    rescue Errno::EEXIST
      false
    end

    def unmark(name, id, kind) = FileUtils.rm_f(receipt_file(name, id, kind))

    # The first value claimed stays, so every process that claims the same id gets the value the first one wrote.
    def claim(name, id, kind, value, &)
      return value if write_once(receipt_file(name, id, kind), value) == :delivered

      claimed(name, id, kind, &)
    end

    # The value claimed for ID, or nil while nothing claimed it. A value the block rejects is damaged.
    def claimed(name, id, kind)
      path = receipt_file(name, id, kind)
      value = read_regular(path) or raise Error, "#{path} is not a regular file"
      return value if !block_given? || yield(value)

      raise Damaged, "#{path} is damaged"
    rescue Errno::ENOENT
      nil
    end

    # VALUE in place of what was claimed for ID, and what every later claim reads back. Only a caller that holds the
    # lock every claim of ID is made under may write over one.
    def reclaim(name, id, kind, value)
      write_atomic(receipt_file(name, id, kind), value)
      value
    end

    # Each claim of KIND in the mailbox of NAME that claimed refuses is reported as a problem.
    def report_damaged_claims(name, kind, &)
      suffix = ".#{kind}"
      Dir.children(File.join(box(name), 'receipts')).sort.each do |file|
        reporting { claimed(name, file.delete_suffix(suffix), kind, &) } if file.end_with?(suffix)
      end
    rescue Errno::ENOENT
      nil
    end

    # Preparing writes and renames in the receipts as keeping does, so a mark that could not be kept fails here.
    def prepare_mark(name, id, kind) = write_atomic(pending_mark(name, id, kind), '')

    def keep_mark(name, id, kind)
      File.rename(pending_mark(name, id, kind), receipt_file(name, id, kind))
      sync_directory(File.join(box(name), 'receipts'))
    rescue Errno::ENOENT
      nil
    end

    private

    def check_new(address)
      return unless address.team == Address::SYSTEM

      raise Error, "#{address.key} is in the scope of keryx's own services, which no address joins"
    end

    def take(lock, within)
      deadline = @clock.call + within
      until lock.flock(File::LOCK_EX | File::LOCK_NB)
        if @clock.call >= deadline
          raise Busy, "#{lock.path} stayed locked by another keryx command for #{within}s; try again, or end that " \
                      'command if it is stuck'
        end

        @sleeper.call(LOCK_POLL_SECONDS)
      end
    end

    def box(name) = File.join(root, ADDRESSES, split(name).first)

    def address_file(name) = File.join(box(name), 'address.json')

    def occupant_file(name) = File.join(box(name), 'occupant.json')

    def receipt_file(name, id, kind) = File.join(box(name), 'receipts', "#{id}.#{kind}")

    def pending_mark(name, id, kind) = "#{receipt_file(name, id, kind)}.pending"

    def require_address(name)
      raise Error, "no address #{name}" unless address?(name)
    end

    def read_ids(name) = ids_in(File.join(box(name), READ)).to_set
  end
end
