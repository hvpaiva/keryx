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
require_relative 'spawned'

module Keryx
  AddressRecord = Data.define(:name, :role, :created_at) do
    def self.from_record(data)
      name, role = data.values_at('name', 'role')
      raise TypeError, 'the name or the role is not text' unless [name, role].all? { it.nil? || it.is_a?(String) }

      new(name:, role:, created_at: Time.iso8601(data['created_at'].to_s))
    end
  end
  StoredMessage = Data.define(:message, :state)

  class Store
    include Files

    class Busy < Error; end

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

    def self.reference(text)
      reference = text.to_s.upcase
      return reference if reference.size >= MINIMUM_PREFIX

      raise Error, "message id #{reference.inspect} is too short; give at least #{MINIMUM_PREFIX} characters"
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

      Dir.children(base).select { Address::NAME.match?(it) && File.file?(address_file(it)) }.sort
    end

    def address?(name) = File.file?(address_file(name))

    def address(name)
      data = read_json(address_file(name)) or return nil
      AddressRecord.from_record(data)
    rescue ArgumentError, KeyError, TypeError, NotAnObject
      raise Error, "#{address_file(name)} is damaged"
    end

    def create_address(name, role: nil, now: Time.now.utc)
      Address.validate_name(name)
      BOX_DIRS.each { FileUtils.mkdir_p(File.join(box(name), it), mode: DIR_MODE) }
      current = address(name)
      return current if current && (role.nil? || role == current.role)

      record = AddressRecord.new(name:, role: role || current&.role, created_at: current&.created_at || now)
      write_atomic(address_file(name), JSON.generate(record.to_h.merge(created_at: record.created_at.utc.iso8601)))
      record
    end

    def occupant(name)
      data = read_json(occupant_file(name)) or return nil
      Occupant.from_record(data)
    rescue ArgumentError, KeyError, TypeError, NotAnObject
      raise Error, "#{occupant_file(name)} is damaged"
    end

    def bind(name, occupant)
      require_address(name)
      write_atomic(occupant_file(name), JSON.generate(occupant.record))
    end

    def unbind(name) = FileUtils.rm_f(occupant_file(name))

    # What spawn recorded about the session it started, until a session joins the address. A damaged record is none,
    # since the join that reads it removes it.
    def spawned(name)
      Spawned.from_record(read_json(spawned_file(name)))
    rescue Error
      nil
    end

    def record_spawned(name, spawned)
      require_address(name)
      write_atomic(spawned_file(name), JSON.generate(spawned.record))
    end

    def forget_spawned(name) = FileUtils.rm_f(spawned_file(name))

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

    def mailbox(name)
      read = read_ids(name)
      messages_in(File.join(box(name), MAIL)).map { StoredMessage.new(it, read.include?(it.id) ? :read : :unread) }
    end

    def unread(name)
      read = read_ids(name)
      messages_in(File.join(box(name), MAIL)) { !read.include?(it) }
    end

    # By id, each request among MESSAGES that its own sender withdrew in the mailbox of NAME, with that withdrawal.
    def withdrawals(name, messages)
      requests = messages.select(&:request?)
      return {} if requests.empty?

      pulled = messages_in(File.join(box(name), MAIL)).select(&:withdrawal?).group_by(&:in_reply_to)
      requests.to_h { |request| [request.id, pulled[request.id]&.find { it.withdraws?(request) }] }.compact
    end

    def find(name, reference)
      reference = Store.reference(reference)
      ids = ids_in(File.join(box(name), MAIL)).select { it.start_with?(reference) }
      raise Error, "#{reference} matches #{ids.size} messages (#{ids.join(', ')}); type more of the id" if ids.size > 1

      message = ids.one? && read_message(File.join(box(name), MAIL, "#{ids.first}.json"))
      raise Error, "no message #{reference} in the mailbox of #{name}" unless message

      StoredMessage.new(message, read_ids(name).include?(message.id) ? :read : :unread)
    end

    def mark_read(name, id)
      make_dirs(box(name), [READ])
      link(File.join(box(name), MAIL, "#{id}.json"), File.join(box(name), READ, "#{id}.json")) == :delivered
    rescue Errno::ENOENT
      raise Error, "no message #{id} in the mailbox of #{name}"
    end

    def outbox = @outbox ||= Outbox.new(root, problems: @problems)

    def all_messages
      kept = address_names.flat_map { |name| mailbox(name).map { [name, it] } }
      sent = outbox.outgoing.reject { it.state == :refused }.map { [nil, StoredMessage.new(it.message, it.state)] }
      kept + sent
    end

    def locate(id) = all_messages.find { |_name, stored| stored.message.id == id }

    # Only this machine writes its outbox, and nothing that arrives from another machine has the host of its
    # recipient, so these are the requests NAME sent from here, under whatever name the machine had then.
    def sent_requests(name)
      all_messages.filter_map do |holder, stored|
        request = stored.message
        sender, host = request.from.split('@')
        [holder, request] if request.request? && sender == name && (holder.nil? || host == request.to.split('@').last)
      end
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

    # The first value claimed stays, so every process that claims the same id gets the value the first one wrote.
    def claim(name, id, kind, value)
      path = receipt_file(name, id, kind)
      return value if write_once(path, value) == :delivered

      read_regular(path) or raise Error, "#{path} is not a regular file"
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

    def box(name) = File.join(root, ADDRESSES, Address.validate_name(name))

    def address_file(name) = File.join(box(name), 'address.json')

    def occupant_file(name) = File.join(box(name), 'occupant.json')

    def spawned_file(name) = File.join(box(name), 'spawned.json')

    def receipt_file(name, id, kind) = File.join(box(name), 'receipts', "#{id}.#{kind}")

    def pending_mark(name, id, kind) = "#{receipt_file(name, id, kind)}.pending"

    def require_address(name)
      raise Error, "no address #{name}" unless address?(name)
    end

    def read_ids(name) = ids_in(File.join(box(name), READ)).to_set
  end
end
