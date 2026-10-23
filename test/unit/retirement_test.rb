# frozen_string_literal: true

require 'test_helper'

class RetirementTest < Minitest::Test
  include TempDir
  include Factory

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def test_retire_drops_the_session_records_and_keeps_the_mailbox
    store.create_address('rev-1', role: 'reviewer', now: NOW)
    message = build_message(to: 'rev-1@athena')
    store.deliver('rev-1', message)
    store.bind('rev-1', build_occupant(pid: 42))
    store.record_spawned('rev-1', Keryx::Spawned.new(director: 'orq', harness: 'claude', herdr_socket: '/h.sock',
                                                     herdr_pane: 'w1:p2'))
    store.retire('rev-1', by: 'person@athena', now: NOW + 60)

    assert_equal Keryx::RetiredRecord.new(retired_at: NOW + 60, by: 'person@athena'), store.retired('rev-1')
    assert_equal({ 'retired_at' => '2026-10-22T17:01:00Z', 'by' => 'person@athena' },
                 JSON.parse(File.read(tmp('state', 'addresses', 'rev-1', 'retired.json'))))
    assert_nil store.occupant('rev-1')
    assert_nil store.spawned('rev-1')
    assert_equal 'reviewer', store.address('rev-1').role
    assert_equal [Keryx::StoredMessage.new(message, :unread)], store.mailbox('rev-1')
  end

  def test_current_names_leave_out_a_retired_address_that_address_names_keeps
    %w[orq rev-1].each { store.create_address(it) }
    store.retire('rev-1', by: 'orq@athena', now: NOW)

    assert_equal %w[orq rev-1], store.address_names
    assert_equal %w[orq], store.current_names
    refute store.retired?('orq')
    assert_nil store.retired('orq')
  end

  def test_revive_takes_back_only_the_retirement
    store.create_address('rev-1', role: 'reviewer')
    store.deliver('rev-1', build_message(to: 'rev-1@athena'))
    store.retire('rev-1', by: 'orq@athena', now: NOW)
    store.revive('rev-1')

    refute store.retired?('rev-1')
    assert_equal %w[rev-1], store.current_names
    assert_equal 1, store.unread('rev-1').size
    assert_raises(Keryx::Error) { store.retire('ghost', by: 'orq@athena', now: NOW) }
  end

  def test_a_damaged_retirement_still_retires_and_names_its_file
    store.create_address('rev-1')
    File.write(tmp('state', 'addresses', 'rev-1', 'retired.json'), '{"retired_at":"never"}')

    assert store.retired?('rev-1')
    assert_empty store.current_names
    assert_match(/retired.json is damaged/, assert_raises(Keryx::Error) { store.retired('rev-1') }.message)
  end
end
