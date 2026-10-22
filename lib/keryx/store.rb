# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'
require 'time'
require_relative 'address'
require_relative 'error'
require_relative 'message'
require_relative 'occupant'

module Keryx
  AddressRecord = Data.define(:name, :role, :created_at)
  StoredMessage = Data.define(:message, :state)

  class Store
    ADDRESSES = 'addresses'
    STATE_DIRS = { unread: 'new', read: 'cur' }.freeze
    BOX_DIRS = %w[tmp new cur receipts].freeze
    MESSAGE_FILE = /\A(?<id>[0-9A-HJKMNP-TV-Z]{26})\.json\z/
    MINIMUM_PREFIX = 4
    DIR_MODE = 0o700
    FILE_MODE = 0o600

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
      AddressRecord.new(name: data['name'], role: data['role'], created_at: Time.iso8601(data['created_at']))
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
    end

    def bind(name, occupant)
      require_address(name)
      write_atomic(occupant_file(name), JSON.generate(occupant.record))
    end

    def unbind(name) = FileUtils.rm_f(occupant_file(name))

    def deliver(name, message)
      require_address(name)
      file = "#{message.id}.json"
      return :duplicate if STATE_DIRS.values.any? { File.exist?(File.join(box(name), it, file)) }

      temporary = File.join(box(name), 'tmp', "#{message.id}.#{Process.pid}.#{SecureRandom.hex(4)}")
      write_file(temporary, message.to_json)
      link(temporary, File.join(box(name), 'new', file))
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    def mailbox(name)
      STATE_DIRS.flat_map { |state, dir| messages_in(File.join(box(name), dir)).map { StoredMessage.new(it, state) } }
                .sort_by { it.message.id }
    end

    def unread(name) = mailbox(name).select { it.state == :unread }.map(&:message)

    def find(name, reference)
      reference = Store.reference(reference)
      matches = mailbox(name).select { it.message.id.start_with?(reference) }
      return matches.first if matches.one?

      raise Error, ambiguous(reference, matches) if matches.size > 1

      raise Error, "no message #{reference} in the mailbox of #{name}"
    end

    def mark_read(name, id)
      File.rename(File.join(box(name), 'new', "#{id}.json"), File.join(box(name), 'cur', "#{id}.json"))
      true
    rescue Errno::ENOENT
      return false if File.exist?(File.join(box(name), 'cur', "#{id}.json"))

      raise Error, "no message #{id} in the mailbox of #{name}"
    end

    def all_messages = address_names.flat_map { |name| mailbox(name).map { [name, it] } }

    def locate(id) = all_messages.find { |_name, stored| stored.message.id == id }

    def write_receipt(name, id, kind, data)
      write_atomic(receipt_file(name, id, kind), JSON.generate(data))
    end

    def receipt(name, id, kind) = read_json(receipt_file(name, id, kind))

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

    def link(source, target)
      File.link(source, target)
      sync_directory(File.dirname(target))
      :delivered
    rescue Errno::EEXIST
      :duplicate
    end

    def messages_in(dir)
      return [] unless File.directory?(dir)

      Dir.children(dir).sort.filter_map do |file|
        next unless MESSAGE_FILE.match?(file)

        read_message(File.join(dir, file))
      end
    end

    def read_message(path)
      Message.from_json(File.read(path))
    rescue Errno::ENOENT
      nil
    rescue Error => e
      @problems << "skipped #{path}: #{e.message}"
      nil
    end

    def read_json(path)
      JSON.parse(File.read(path))
    rescue Errno::ENOENT
      nil
    rescue JSON::ParserError => e
      raise Error, "#{path} is not valid JSON (#{e.message.lines.first.strip})"
    end

    def ambiguous(reference, matches)
      "#{reference} matches #{matches.size} messages (#{matches.map { it.message.id }.join(', ')}); type more of the id"
    end

    def write_atomic(path, content)
      temporary = "#{path}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp"
      write_file(temporary, content)
      File.rename(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    def write_file(path, content)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, FILE_MODE) do |file|
        file.write(content)
        file.flush
        file.fsync
      end
    end

    def sync_directory(dir)
      File.open(dir, &:fsync)
    rescue SystemCallError
      nil
    end
  end
end
