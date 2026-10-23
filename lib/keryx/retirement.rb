# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'
require_relative 'error'
require_relative 'files'
require_relative 'address'
require_relative 'message'

module Keryx
  # A retired address keeps its files; only this record, and the session records it removed, set it apart.
  RetiredRecord = Data.define(:retired_at, :by) do
    def self.from_record(data)
      raise TypeError, 'by is not an address' unless Address.valid?(data['by'])

      new(retired_at: Time.iso8601(data['retired_at'].to_s), by: data['by'])
    end

    def record = { 'retired_at' => retired_at.utc.iso8601, 'by' => by }
  end

  # How Store retires an address and brings it back, on the paths Store builds.
  module Retirement
    RETIRED = '%s is retired; mail to it is refused'

    def current_names = address_names.reject { retired?(it) }

    # Whatever stands at the path retires the address, so a record that cannot be read never brings one back.
    def retired?(name) = File.exist?(retired_file(name)) || File.symlink?(retired_file(name))

    def retired(name)
      data = read_json(retired_file(name)) or return nil
      RetiredRecord.from_record(data)
    rescue ArgumentError, TypeError, Files::NotAnObject
      raise Error, "#{retired_file(name)} is damaged"
    end

    # The session records go first, so a retire cut short leaves an address nobody holds rather than a retired one
    # that a session restarted in the old pane would find as its own.
    def retire(name, by:, now:)
      require_address(name)
      incarnations(name).each { unbind(it) }
      forget_spawned(name)
      write_atomic(retired_file(name), JSON.generate(RetiredRecord.new(retired_at: now, by:).record))
    end

    def revive(name) = FileUtils.rm_f(retired_file(name))

    private

    def retired_file(name) = File.join(box(name), 'retired.json')
  end
end
