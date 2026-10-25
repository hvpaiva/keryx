# frozen_string_literal: true

require 'test_helper'

class RetirementTest < Minitest::Test
  include TempDir
  include Factory

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def test_retire_drops_the_session_records_and_keeps_the_mailbox
    store.create_address('rev-1.dev', role: 'reviewer', now: NOW)
    message = build_message(to: 'rev-1.dev@athena')
    store.deliver('rev-1.dev', message)
    store.bind('rev-1.dev', build_occupant(pid: 42))
    store.record_spawned('rev-1.dev', Keryx::Spawned.new(director: 'orq.dev', harness: 'claude',
                                                         herdr_socket: '/h.sock', herdr_pane: 'w1:p2'))
    store.retire('rev-1.dev', by: 'person.local@athena', now: NOW + 60)

    assert_equal Keryx::RetiredRecord.new(retired_at: NOW + 60, by: 'person.local@athena'), store.retired('rev-1.dev')
    assert_equal({ 'retired_at' => '2026-10-22T17:01:00Z', 'by' => 'person.local@athena' },
                 JSON.parse(File.read(tmp('state', 'addresses', 'rev-1.dev', 'retired.json'))))
    assert_nil store.occupant('rev-1.dev')
    assert_nil store.spawned('rev-1.dev')
    assert_equal 'reviewer', store.address('rev-1.dev').role
    assert_equal [Keryx::StoredMessage.new(message, :unread)], store.mailbox('rev-1.dev')
  end

  def test_current_names_leave_out_a_retired_address_that_address_names_keeps
    %w[orq.dev rev-1.dev].each { store.create_address(it) }
    store.retire('rev-1.dev', by: 'orq.dev@athena', now: NOW)

    assert_equal %w[orq.dev rev-1.dev], store.address_names
    assert_equal %w[orq.dev], store.current_names
    refute store.retired?('orq.dev')
    assert_nil store.retired('orq.dev')
  end

  def test_revive_takes_back_only_the_retirement
    store.create_address('rev-1.dev', role: 'reviewer')
    store.deliver('rev-1.dev', build_message(to: 'rev-1.dev@athena'))
    store.retire('rev-1.dev', by: 'orq.dev@athena', now: NOW)
    store.revive('rev-1.dev')

    refute store.retired?('rev-1.dev')
    assert_equal %w[rev-1.dev], store.current_names
    assert_equal 1, store.unread('rev-1.dev').size
    assert_raises(Keryx::Error) { store.retire('ghost.dev', by: 'orq.dev@athena', now: NOW) }
  end

  def test_a_damaged_retirement_still_retires_and_names_its_file
    store.create_address('rev-1.dev')
    File.write(tmp('state', 'addresses', 'rev-1.dev', 'retired.json'), '{"retired_at":"never"}')

    assert store.retired?('rev-1.dev')
    assert_empty store.current_names
    assert_match(/retired.json is damaged/, assert_raises(Keryx::Error) { store.retired('rev-1.dev') }.message)
  end
end
