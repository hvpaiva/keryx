# frozen_string_literal: true

require 'test_helper'

class SpawnedTest < Minitest::Test
  include TempDir
  include Factory

  def spawned = Keryx::Spawned.new(director: 'orq.dev', harness: 'claude', herdr_socket: '/h.sock', herdr_pane: 'w1:p2')

  def store = @store ||= Keryx::Store.new(tmp('state')).tap { it.create_address('impl.dev') }

  def test_only_the_harness_spawn_started_in_its_pane_is_the_session_it_started
    started = build_occupant(herdr_socket: '/h.sock', herdr_pane: 'w1:p2')

    assert spawned.started?(started)
    [{ harness: 'codex' }, { herdr_socket: '/other.sock' }, { herdr_pane: 'w1:p3' }].each do |other|
      refute spawned.started?(started.with(**other)), other.inspect
    end
  end

  def test_one_socket_spelled_another_way_is_the_same_socket_and_links_are_not_followed
    started = build_occupant(herdr_socket: '/h.sock', herdr_pane: 'w1:p2')
    File.symlink(tmp('h.sock'), tmp('link.sock'))

    %w[/./h.sock //h.sock /x/../h.sock /h.sock/].each do |socket|
      assert spawned.with(herdr_socket: socket).started?(started), "recorded as #{socket}"
      assert spawned.started?(started.with(herdr_socket: socket)), "joined from #{socket}"
    end
    refute spawned.started?(started.with(herdr_socket: nil))
    assert_equal tmp('link.sock'), Keryx::Spawned.socket(tmp('link.sock'))
  end

  def test_the_record_lasts_until_it_is_forgotten_and_a_damaged_one_is_none
    [spawned.with(director: 'orq.dev/k3m9qz'), spawned].each do |record|
      store.record_spawned('impl.dev', record)

      assert_equal record, store.spawned('impl.dev')
    end
    store.forget_spawned('impl.dev')

    assert_nil store.spawned('impl.dev')
    [spawned.record.merge('director' => 'Orq@x'), spawned.record.merge('director' => 'orq/k3m9qz'),
     spawned.record.merge('herdr_pane' => 2), []].each do |record|
      File.write(tmp('state', 'addresses', 'impl.dev', 'spawned.json'), JSON.generate(record))

      assert_nil store.spawned('impl.dev'), record.inspect
    end
    assert_raises(Keryx::Error) { store.record_spawned('ghost.dev', spawned) }
  end

  def test_the_same_record_is_left_as_it_was_and_given_back
    file = tmp('state', 'addresses', 'impl.dev', 'spawned.json')

    assert_nil store.record_spawned('impl.dev', spawned)
    written = File.stat(file)

    assert_equal spawned, store.record_spawned('impl.dev', spawned, replace: false)
    assert_equal spawned, store.record_spawned('impl.dev', spawned)
    now = File.stat(file)

    assert_equal [written.ino, written.mtime], [now.ino, now.mtime]
  end

  # spawn writes outside the occupants lock, so its record can land between the read and the write of one that does not
  # replace.
  def test_a_record_written_after_the_read_is_kept_and_given_back_without_replace
    other = spawned.with(harness: 'codex', herdr_pane: 'w1:p4')
    reads = 0
    store.define_singleton_method(:spawned) do |name|
      super(name).tap { record_spawned(name, other) if (reads += 1) == 1 }
    end

    assert_equal other, store.record_spawned('impl.dev', spawned, replace: false)
    assert_equal other, Keryx::Store.new(tmp('state')).spawned('impl.dev')
  end

  def test_a_damaged_record_is_written_over_without_replace
    damaged = tmp('state', 'addresses', 'impl.dev', 'spawned.json')
    store
    File.write(damaged, '{')

    assert_nil store.record_spawned('impl.dev', spawned, replace: false)
    assert_equal spawned, store.spawned('impl.dev')
  end

  # spawn writes with no keyword, over whatever waits, and a caller passing replace: false keeps a different record.
  def test_a_different_record_is_kept_only_when_not_replaced_and_given_back_either_way
    other = spawned.with(herdr_pane: 'w1:p3')
    store.record_spawned('impl.dev', spawned)

    assert_equal spawned, store.record_spawned('impl.dev', other, replace: false)
    assert_equal spawned, store.spawned('impl.dev')
    assert_equal spawned, store.record_spawned('impl.dev', other)
    assert_equal other, store.spawned('impl.dev')
  end
end
