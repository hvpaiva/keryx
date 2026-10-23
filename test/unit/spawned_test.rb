# frozen_string_literal: true

require 'test_helper'

class SpawnedTest < Minitest::Test
  include TempDir
  include Factory

  def spawned = Keryx::Spawned.new(director: 'orq', harness: 'claude', herdr_socket: '/h.sock', herdr_pane: 'w1:p2')

  def store = @store ||= Keryx::Store.new(tmp('state')).tap { it.create_address('impl') }

  def test_only_the_harness_spawn_started_in_its_pane_is_the_session_it_started
    started = build_occupant(herdr_socket: '/h.sock', herdr_pane: 'w1:p2')

    assert spawned.started?(started)
    [{ harness: 'codex' }, { herdr_socket: '/other.sock' }, { herdr_pane: 'w1:p3' }].each do |other|
      refute spawned.started?(started.with(**other)), other.inspect
    end
  end

  def test_the_record_lasts_until_it_is_forgotten_and_a_damaged_one_is_none
    store.record_spawned('impl', spawned)

    assert_equal spawned, store.spawned('impl')
    store.forget_spawned('impl')

    assert_nil store.spawned('impl')
    [spawned.record.merge('director' => 'Orq@x'), spawned.record.merge('herdr_pane' => 2), []].each do |record|
      File.write(tmp('state', 'addresses', 'impl', 'spawned.json'), JSON.generate(record))

      assert_nil store.spawned('impl'), record.inspect
    end
    assert_raises(Keryx::Error) { store.record_spawned('ghost', spawned) }
  end
end
