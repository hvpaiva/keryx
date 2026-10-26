# frozen_string_literal: true

require 'json'
require_relative 'error'
require_relative 'spawned'

module Keryx
  # The record spawn and expect write in an address's folder about the session they expect, part of Store.
  module SpawnedRecords
    # What spawn or expect recorded about the session they expect, until a session joins the address. A damaged record
    # is none, and so is one keryx cannot open, since the join that reads it removes it.
    def spawned(name)
      Spawned.from_record(read_json(spawned_file(name)))
    rescue Error, SystemCallError
      nil
    end

    # The one writer of the record, for spawn and expect. It returns the record that waited, and leaves it as it is when
    # it is the same, or when it differs and replace is false.
    def record_spawned(name, spawned, replace: true)
      require_address(name)
      waiting = self.spawned(name)
      return waiting if waiting == spawned || (waiting && !replace)
      return place_spawned(name, spawned) unless replace

      write_atomic(spawned_file(name), JSON.generate(spawned.record))
      waiting
    end

    def forget_spawned(name) = remove(spawned_file(name))

    private

    # Without replace the record goes only where none is, since spawn writes its own outside the occupants lock and one
    # it wrote after the read is kept and returned. A damaged record is none, and is written over.
    def place_spawned(name, spawned)
      content = JSON.generate(spawned.record)
      return if write_once(spawned_file(name), content) == :delivered

      self.spawned(name).tap { write_atomic(spawned_file(name), content) unless it }
    end

    def spawned_file(name) = File.join(box(name), 'spawned.json')
  end
end
