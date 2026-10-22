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
      FileUtils.rm_f(receipt_file(host, id))
    end

    def write_receipt(host, id, data) = write_atomic(receipt_file(host, id), JSON.generate(data))

    def receipt(host, id) = read_receipt(receipt_file(host, id))

    private

    def dir(host)
      raise Error, "invalid host #{host.inspect}" unless Address::HOST.match?(host.to_s)

      File.join(@base, host)
    end

    def receipt_file(host, id) = File.join(dir(host), 'receipts', "#{id}.forward")
  end
end
