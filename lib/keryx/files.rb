# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'
require_relative 'error'
require_relative 'message'

module Keryx
  module Files
    MESSAGE_FILE = /\A(?<id>[0-9A-HJKMNP-TV-Z]{26})\.json\z/
    DIR_MODE = 0o700
    FILE_MODE = 0o600
    # The fields of Bell::Result#record.
    BELL = { 'status' => [String], 'channel' => [String, NilClass], 'detail' => [String, NilClass],
             'at' => [String, NilClass] }.freeze
    RECEIPT = BELL.merge('attempts' => [Integer, NilClass]).freeze

    def self.bell?(value) = value.is_a?(Hash) && BELL.all? { |name, types| types.any? { value[name].is_a?(it) } }

    # The optional fields of a receipt that have the wrong type, a bell among them unless it is a bell record.
    def self.bad_options(receipt)
      bad = RECEIPT.except('status').filter_map { |name, types| name if types.none? { receipt[name].is_a?(it) } }
      receipt['bell'].nil? || bell?(receipt['bell']) ? bad : [*bad, 'bell']
    end

    class NotAnObject < Error; end

    private

    def make_dirs(base, dirs) = dirs.each { FileUtils.mkdir_p(File.join(base, it), mode: DIR_MODE) }

    def drop_in(base, dir, message)
      temporary = File.join(base, 'tmp', "#{message.id}.#{Process.pid}.#{SecureRandom.hex(4)}")
      write_file(temporary, message.to_json)
      link(temporary, File.join(base, dir, "#{message.id}.json"))
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    def link(source, target)
      File.link(source, target)
      sync_directory(File.dirname(target))
      :delivered
    rescue Errno::EEXIST
      :duplicate
    end

    def ids_in(dir)
      return [] unless File.directory?(dir)

      Dir.children(dir).filter_map { MESSAGE_FILE.match(it)&.[](:id) }.sort
    end

    def messages_in(dir)
      ids_in(dir).filter_map { |id| read_message(File.join(dir, "#{id}.json")) if !block_given? || yield(id) }
    end

    def read_message(path)
      text = read_regular(path) or raise Error, 'not a regular file'
      message = Message.from_json(text)
      return message if File.basename(path, '.json') == message.id

      raise Error, "the file name does not match the message id #{message.id}"
    rescue Errno::ENOENT
      nil
    rescue Error => e
      @problems << "skipped #{path}: #{e.message}"
      nil
    end

    def read_json(path)
      text = read_regular(path) or raise Error, "#{path} is not a regular file"
      data = JSON.parse(text)
      return data if data.is_a?(Hash)

      raise NotAnObject, "#{path} is not a JSON object"
    rescue Errno::ENOENT
      nil
    rescue JSON::ParserError => e
      raise Error, "#{path} is not valid JSON (#{e.message.lines.first.strip})"
    end

    def read_receipt(path)
      receipt = read_json(path) or return nil
      field, = RECEIPT.find { |name, types| types.none? { receipt[name].is_a?(it) } }
      raise Error, "#{path} has a bad #{field}" if field

      receipt
    rescue Error => e
      @problems << "#{e.message}; it is ignored until keryx writes it again"
      nil
    end

    # Without O_NONBLOCK a named pipe waits for a writer, and a socket fails to open; neither is a regular file.
    def read_regular(path)
      File.open(path, File::RDONLY | File::NONBLOCK) { |file| file.read if file.stat.file? }
    rescue Errno::ENXIO, Errno::EOPNOTSUPP
      nil
    end

    def write_atomic(path, content)
      temporary = "#{path}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp"
      write_file(temporary, content)
      File.rename(temporary, path)
      sync_directory(File.dirname(path))
    ensure
      FileUtils.rm_f(temporary) if temporary
    end

    def write_once(path, content)
      temporary = "#{path}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp"
      write_file(temporary, content)
      link(temporary, path)
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
