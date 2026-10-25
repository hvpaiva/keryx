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
end
