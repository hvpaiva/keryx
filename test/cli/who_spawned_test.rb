# frozen_string_literal: true

require 'test_helper'

class WhoSpawnedTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers

  SPAWNED = { 'director' => 'person.local@athena', 'harness' => 'claude', 'herdr_socket' => SOCKET,
              'herdr_pane' => 'w1:p2' }.freeze
  # The record as spawn writes it, with the director as a name.
  RECORD = SPAWNED.merge('director' => 'person.local').freeze

  def addresses = JSON.parse(keryx('who', '--all', '-o', 'json').out)['addresses'].to_h { [it['address'], it] }

  def spawned = addresses.transform_values { it['spawned'] }

  def write_record(text)
    tmp('state', 'addresses', 'rev-1.dev', 'spawned.json').tap { File.write(it, text) }
  end

  def test_a_spawn_waiting_for_its_session_gives_the_pane_it_started_it_in_until_the_join
    waiting = nil
    session_joins
    joining = herdr.on_start
    herdr.on_start = lambda do |*started|
      waiting = spawned.fetch('rev-1.dev@athena')
      joining.call(*started)
    end
    result = spawn('rev-1.dev', '--harness', 'claude', 'Review it')

    assert_equal 0, result.status, result.err
    assert_equal SPAWNED, waiting
    assert_nil spawned.fetch('rev-1.dev@athena')
    assert_equal 'person.local@athena', addresses.fetch('rev-1.dev@athena')['director']
  end

  def test_a_spawn_that_gave_up_waiting_keeps_its_record_until_the_session_joins
    session_runs

    assert_equal 3, spawn('rev-1.dev', '--harness', 'claude', '--timeout', '5s', 'Review it').status
    assert_equal SPAWNED, spawned.fetch('rev-1.dev@athena')

    alive << 500
    joins('rev-1.dev', claude(500).merge(in_pane(SOCKET, 'w1:p2')))

    assert_nil spawned.fetch('rev-1.dev@athena')
    assert_equal 'person.local@athena', addresses.fetch('rev-1.dev@athena')['director']
  end

  def test_an_address_spawn_started_no_session_for_has_none
    join_claude('orq.dev', 111)
    keryx('leave', env: join_claude('rev-1.dev', 222))

    assert_equal [nil, nil], spawned.values_at('orq.dev@athena', 'rev-1.dev@athena')
  end

  def test_the_record_is_the_stable_address_s_even_beside_a_holder_and_never_a_session_address_s
    join_claude('rev-1.dev', 222)
    alive << 333
    keryx('join', 'rev-1.dev', '--force', env: claude(333))
    store.record_spawned('rev-1.dev', Keryx::Spawned.from_record(RECORD))
    displaced = spawned.find { |address, _| address.start_with?('rev-1.dev@athena/') }

    assert_equal SPAWNED, spawned.fetch('rev-1.dev@athena')
    assert_nil displaced.last
  end

  def test_a_record_that_does_not_parse_or_lacks_a_field_is_none
    keryx('leave', env: join_claude('rev-1.dev', 222))
    ['{nope', '[]', JSON.generate(RECORD.except('herdr_pane')),
     JSON.generate(RECORD.merge('director' => 'not an address'))].each do |text|
      write_record(text)
      result = keryx('who', '--all', '-o', 'json')

      assert_equal 0, result.status, result.err
      assert_nil JSON.parse(result.out)['addresses'].find { it['address'] == 'rev-1.dev@athena' }['spawned'], text
    end
  end

  def test_a_record_keryx_cannot_open_is_none
    skip 'root reads a file whatever its mode' if Process.uid.zero?
    keryx('leave', env: join_claude('rev-1.dev', 222))
    File.chmod(0, write_record(JSON.generate(RECORD)))

    assert_nil spawned.fetch('rev-1.dev@athena')
  end
end
