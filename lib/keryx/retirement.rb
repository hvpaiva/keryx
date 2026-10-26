# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'
require_relative 'error'
require_relative 'files'
require_relative 'address'
require_relative 'message'

module Keryx
  # A retired address keeps its files; only this record, and the session records it removed, set it apart. Once keryx
  # purge removed its mail, the record says when and by which address, both or neither.
  RetiredRecord = Data.define(:retired_at, :by, :purged_at, :purged_by) do
    def initialize(retired_at:, by:, purged_at: nil, purged_by: nil) = super

    def self.from_record(data)
      raise TypeError, 'by is not an address' unless Address.valid?(data['by'])

      new(retired_at: Time.iso8601(data['retired_at'].to_s), by: data['by'], **purge(data))
    end

    def self.purge(data)
      at, by = data.values_at('purged_at', 'purged_by')
      return {} if at.nil? && by.nil?
      raise TypeError, 'purged_by is not an address' unless Address.valid?(by)

      { purged_at: Time.iso8601(at.to_s), purged_by: by }
    end

    def purged? = !purged_at.nil?

    def purge_stamp = "#{purged_at.utc.strftime('%Y-%m-%d %H:%M:%S UTC')} by #{purged_by}"

    def record
      { 'retired_at' => retired_at.utc.iso8601, 'by' => by, 'purged_at' => purged_at&.utc&.iso8601,
        'purged_by' => purged_by }.compact
    end
  end

  # What keryx purge removes from an address's folder, the paths by folder, and the ids of the messages it keeps.
  PurgePlan = Data.define(:removed, :kept) do
    def empty? = removed.values.all?(&:empty?)
  end

  # How Store retires an address and brings it back, on the paths Store builds.
  module Retirement
    RETIRED = '%s is retired; mail to it is refused'
    # The folders keryx purge empties, the mail last, so a purge cut short leaves messages rather than marks of them.
    PURGED = %w[tmp receipts read mail].freeze
    # mail/ keeps the answers purge keeps, and read/ their read marks.
    KEEPING = %w[read mail].freeze

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

    def revive(name) = remove(retired_file(name))

    # Whether the folder of NAME is a folder of the store itself, and not a link to one elsewhere.
    def own_folder?(name) = File.lstat(box(name)).directory?

    # What purge removes from the folder of NAME: each entry of the folders it empties, except a regular file of mail/
    # or read/ that holds a message KEEP names, and a folder that is a link or no folder at all, as a whole.
    def purge_plan(name, keep)
      removed = PURGED.to_h { |dir| [dir, purged_entries(name, dir, keep)] }
      mail = File.join(box(name), 'mail')
      kept = removed['mail'].include?(mail) ? [] : keep.select { regular?(File.join(mail, "#{it}.json")) }.sort
      PurgePlan.new(removed:, kept:)
    end

    # The mark goes first, so a purge cut short leaves the address purged and the next one finds what is left. A mark
    # written before stays as it was. rm_r reads each entry with lstat and removes a link without following it.
    def purge(name, plan, by:, now:)
      record = retired(name) or raise Error, "#{name} is not retired"
      unless record.purged?
        write_atomic(retired_file(name), JSON.generate(record.with(purged_at: now, purged_by: by).record))
      end
      plan.removed.each do |dir, paths|
        paths.each { remove_tree(it) }
        remove_empty(File.join(box(name), dir))
      end
    end

    private

    def purged_entries(name, dir, keep)
      path = File.join(box(name), dir)
      return [path] unless File.lstat(path).directory?

      Dir.children(path).sort.filter_map do |child|
        entry = File.join(path, child)
        entry unless KEEPING.include?(dir) && kept?(entry, keep)
      end
    rescue Errno::ENOENT
      []
    end

    def kept?(path, keep)
      id = Files::MESSAGE_FILE.match(File.basename(path))&.[](:id)
      !id.nil? && keep.include?(id) && regular?(path)
    end

    def regular?(path)
      File.lstat(path).file?
    rescue Errno::ENOENT
      false
    end

    # rm_r can stop partway, so the change is noted whether it finished or not.
    def remove_tree(path)
      FileUtils.rm_r(path)
    ensure
      changed!
    end

    # A folder that still keeps answers stays.
    def remove_empty(path)
      Dir.rmdir(path)
      changed!
    rescue Errno::ENOTEMPTY, Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    def retired_file(name) = File.join(box(name), 'retired.json')
  end
end
