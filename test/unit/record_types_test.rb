# frozen_string_literal: true

require 'test_helper'

class RecordTypesTest < Minitest::Test
  include TempDir
  include Factory

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def test_an_occupant_file_with_a_field_of_the_wrong_type_is_damaged
    store.create_address('rev-1.dev')
    path = tmp('state', 'addresses', 'rev-1.dev', 'occupant.json')
    record = build_occupant(pid: 7, herdr_socket: '/h.sock', herdr_pane: 'w1:p1').record
    [{ 'pid' => [] }, { 'pid' => '7' }, { 'pid' => 7.0 }, { 'pid' => 0 }, { 'pid' => -7 }, { 'pid' => 2**31 },
     { 'harness' => 5 }, { 'session_id' => {} }, { 'started' => 1 }, { 'claude_socket' => true },
     { 'herdr_socket' => [] }, { 'herdr_pane' => 3 }, { 'cwd' => false }, { 'joined_at' => true }].each do |field|
      File.write(path, JSON.generate(record.merge(field)))

      assert_match(/occupant.json is damaged/, assert_raises(Keryx::Error, field.inspect) { store.occupant('rev-1.dev') }
                                                 .message)
    end
    File.write(path, '[]')

    assert_match(/occupant.json is damaged/, assert_raises(Keryx::Error) { store.occupant('rev-1.dev') }.message)
  end

  def test_an_occupant_file_reads_a_process_id_or_none
    store.create_address('rev-1.dev')
    path = tmp('state', 'addresses', 'rev-1.dev', 'occupant.json')

    pids = [nil, 1, (2**31) - 1].map do |pid|
      File.write(path, JSON.generate(build_occupant.record.merge('pid' => pid)))
      store.occupant('rev-1.dev').pid
    end

    assert_equal [nil, 1, (2**31) - 1], pids
  end

  def test_an_address_file_with_a_name_or_role_that_is_not_text_is_damaged
    store.create_address('rev-1.dev', now: NOW)
    path = tmp('state', 'addresses', 'rev-1.dev', 'address.json')
    record = { 'name' => 'rev-1.dev', 'role' => 'reviewer', 'created_at' => NOW.iso8601 }
    [{ 'name' => 5 }, { 'role' => ['reviewer'] }, { 'created_at' => true }].each do |field|
      File.write(path, JSON.generate(record.merge(field)))

      assert_match(/address.json is damaged/, assert_raises(Keryx::Error, field.inspect) { store.address('rev-1.dev') }
                                                .message)
    end
    File.write(path, JSON.generate(record.merge('role' => nil)))

    assert_nil store.address('rev-1.dev').role
  end
end
