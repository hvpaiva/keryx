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

module Keryx
  AddressRecord = Data.define(:name, :role, :created_at)
  StoredMessage = Data.define(:message, :state)

  class Store
    include Files

    ADDRESSES = 'addresses'
    MAIL = 'mail'
    READ = 'read'
    BOX_DIRS = ['tmp', MAIL, READ, 'receipts'].freeze
    MINIMUM_PREFIX = 4

    attr_reader :root, :problems

    def self.reference(text)
      reference = text.to_s.upcase
      return reference if reference.size >= MINIMUM_PREFIX

      raise Error, "message id #{reference.inspect} is too short; give at least #{MINIMUM_PREFIX} characters"
    end

    def initialize(root)
      @root = root
      @problems = []
    end

    def address_names
      base = File.join(root, ADDRESSES)
      return [] unless File.directory?(base)

      Dir.children(base).select { Address::NAME.match?(it) && File.file?(address_file(it)) }.sort
    end

    def address?(name) = File.file?(address_file(name))

    def address(name)
      data = read_json(address_file(name)) or return nil
      AddressRecord.new(name: data['name'], role: data['role'], created_at: Time.iso8601(data['created_at'].to_s))
    rescue ArgumentError, KeyError, TypeError
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
    rescue ArgumentError, KeyError, TypeError
      raise Error, "#{occupant_file(name)} is damaged"
    end

    def bind(name, occupant)
      require_address(name)
      write_atomic(occupant_file(name), JSON.generate(occupant.record))
    end

    def unbind(name) = FileUtils.rm_f(occupant_file(name))

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

    def write_receipt(name, id, kind, data)
      write_atomic(receipt_file(name, id, kind), JSON.generate(data))
    end

    def receipt(name, id, kind) = read_json(receipt_file(name, id, kind))

    def marked?(name, id, kind) = File.exist?(receipt_file(name, id, kind))

    def mark_once(name, id, kind)
      File.open(receipt_file(name, id, kind), File::WRONLY | File::CREAT | File::EXCL, FILE_MODE) { true }
    rescue Errno::EEXIST
      false
    end

    private

    def box(name) = File.join(root, ADDRESSES, Address.validate_name(name))

    def address_file(name) = File.join(box(name), 'address.json')

    def occupant_file(name) = File.join(box(name), 'occupant.json')

    def receipt_file(name, id, kind) = File.join(box(name), 'receipts', "#{id}.#{kind}")

    def require_address(name)
      raise Error, "no address #{name}" unless address?(name)
    end

    def read_ids(name) = ids_in(File.join(box(name), READ)).to_set
  end
end
