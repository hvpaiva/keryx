# frozen_string_literal: true

require 'test_helper'
require 'socket'
require 'timeout'

class StoreTest < Minitest::Test
  include TempDir
  include Factory

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def test_create_address_makes_a_private_mailbox
    record = store.create_address('rev-1.dev', role: 'reviewer', now: NOW)

    assert_equal Keryx::AddressRecord.new(member: 'rev-1', team: 'dev', role: 'reviewer', created_at: NOW), record
    assert_equal 0o700, File.stat(tmp('state', 'addresses', 'rev-1.dev', 'mail')).mode & 0o777
  end

  def test_create_address_is_idempotent_and_changes_the_role_only_when_given
    store.create_address('rev-1.dev', role: 'reviewer', now: NOW)
    store.create_address('rev-1.dev', now: NOW + 60)

    record = Keryx::AddressRecord.new(member: 'rev-1', team: 'dev', role: 'reviewer', created_at: NOW)

    assert_equal record, store.address('rev-1.dev')
    assert_equal 'auditor', store.create_address('rev-1.dev', role: 'auditor').role
  end

  def test_address_names_lists_only_created_addresses
    store.create_address('rev-2.dev')
    store.create_address('orq.dev')
    FileUtils.mkdir_p(tmp('state', 'addresses', 'stray'))

    assert_equal %w[orq.dev rev-2.dev], store.address_names
    assert_empty Keryx::Store.new(tmp('elsewhere')).address_names
  end

  def test_a_name_outside_the_rules_never_becomes_a_path
    assert_raises(Keryx::Error) { store.address('../etc') }
    assert_raises(Keryx::Error) { store.create_address('Rev') }
  end

  def test_deliver_puts_a_private_file_in_mail
    store.create_address('rev-1.dev')
    message = build_message(to: 'rev-1.dev@athena')

    assert_equal :delivered, store.deliver('rev-1.dev', message)
    assert_equal [message], store.unread('rev-1.dev')
    path = tmp('state', 'addresses', 'rev-1.dev', 'mail', "#{message.id}.json")

    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_empty Dir.children(tmp('state', 'addresses', 'rev-1.dev', 'tmp'))
  end

  def test_delivering_the_same_message_twice_is_harmless
    store.create_address('rev-1.dev')
    message = build_message(to: 'rev-1.dev@athena')
    store.deliver('rev-1.dev', message)

    assert_equal :duplicate, store.deliver('rev-1.dev', message)
    store.mark_read('rev-1.dev', message.id)

    assert_equal :duplicate, store.deliver('rev-1.dev', message)
    assert_equal 1, store.mailbox('rev-1.dev').size
  end

  def test_concurrent_deliveries_of_one_message_store_it_once
    store.create_address('rev-1.dev')
    message = build_message(to: 'rev-1.dev@athena')
    results = Array.new(4) { Thread.new { store.deliver('rev-1.dev', message) } }.map(&:value)

    assert_equal 1, results.count(:delivered)
    assert_equal 1, store.mailbox('rev-1.dev').size
  end

  def store_pausing_before_link(paused, resume)
    Keryx::Store.new(tmp('state')).tap do |slow|
      slow.define_singleton_method(:link) do |source, target|
        paused << true
        resume.pop
        super(source, target)
      end
    end
  end

  def test_a_delivery_that_races_a_read_still_stores_the_message_once
    store.create_address('rev-1.dev')
    message = build_message(to: 'rev-1.dev@athena')
    paused = Queue.new
    resume = Queue.new
    late = Thread.new { store_pausing_before_link(paused, resume).deliver('rev-1.dev', message) }
    paused.pop
    first = store.deliver('rev-1.dev', message)
    store.mark_read('rev-1.dev', message.id)
    resume << true

    assert_equal %i[delivered duplicate], [first, late.value]
    assert_equal [:read], store.mailbox('rev-1.dev').map(&:state)
  end

  def test_unread_opens_only_the_unread_messages
    store.create_address('rev-1.dev')
    read, unread = [1, 2].map { build_message(to: 'rev-1.dev@athena', id: Keryx::Ulid.generate(NOW + it)) }
    [read, unread].each { store.deliver('rev-1.dev', it) }
    store.mark_read('rev-1.dev', read.id)
    File.write(tmp('state', 'addresses', 'rev-1.dev', 'mail', "#{read.id}.json"), '{')

    assert_equal [unread], store.unread('rev-1.dev')
    assert_empty store.problems
  end

  def test_deliver_refuses_an_unknown_address
    assert_raises(Keryx::Error) { store.deliver('ghost.dev', build_message(to: 'ghost.dev@athena')) }
  end

  def test_mark_read_records_the_read_once
    store.create_address('rev-1.dev')
    message = build_message(to: 'rev-1.dev@athena')
    store.deliver('rev-1.dev', message)

    assert store.mark_read('rev-1.dev', message.id)
    refute store.mark_read('rev-1.dev', message.id)
    assert_equal [:read], store.mailbox('rev-1.dev').map(&:state)
    assert_raises(Keryx::Error) { store.mark_read('rev-1.dev', Keryx::Ulid.generate) }
  end

  def test_mailbox_sorts_by_id_across_states
    store.create_address('rev-1.dev')
    first, second, third = [1, 2, 3].map { build_message(to: 'rev-1.dev@athena', id: Keryx::Ulid.generate(NOW + it)) }
    [third, first, second].each { store.deliver('rev-1.dev', it) }
    store.mark_read('rev-1.dev', second.id)

    assert_equal([first.id, second.id, third.id], store.mailbox('rev-1.dev').map { it.message.id })
    assert_equal %i[unread read unread], store.mailbox('rev-1.dev').map(&:state)
  end

  def test_find_takes_a_full_id_or_a_unique_prefix
    store.create_address('rev-1.dev')
    message = build_message(to: 'rev-1.dev@athena')
    store.deliver('rev-1.dev', message)

    assert_equal message, store.find('rev-1.dev', message.id).message
    assert_equal message, store.find('rev-1.dev', message.id[0, 6].downcase).message
  end

  def test_find_rejects_short_ambiguous_and_missing_references
    store.create_address('rev-1.dev')
    ids = Array.new(2) { Keryx::Ulid.generate(NOW) }
    ids.each { store.deliver('rev-1.dev', build_message(to: 'rev-1.dev@athena', id: it)) }

    assert_match(/too short/, assert_raises(Keryx::Error) { store.find('rev-1.dev', '01J') }.message)
    assert_match(/matches 2 messages/, assert_raises(Keryx::Error) { store.find('rev-1.dev', ids[0][0, 10]) }.message)
    assert_match(/no message/, assert_raises(Keryx::Error) { store.find('rev-1.dev', 'ZZZZ') }.message)
  end

  def test_a_damaged_file_is_skipped_and_reported
    store.create_address('rev-1.dev')
    good = build_message(to: 'rev-1.dev@athena')
    store.deliver('rev-1.dev', good)
    File.write(tmp('state', 'addresses', 'rev-1.dev', 'mail', "#{Keryx::Ulid.generate}.json"), '{')
    File.write(tmp('state', 'addresses', 'rev-1.dev', 'mail', 'notes.txt'), 'ignored')

    assert_equal [good], store.unread('rev-1.dev')
    assert_equal 1, store.problems.size
    assert_match(/not valid JSON/, store.problems.first)
  end

  def test_an_entry_that_is_not_a_regular_file_is_skipped_without_waiting_on_it
    store.create_address('rev-1.dev')
    good = build_message(to: 'rev-1.dev@athena')
    store.deliver('rev-1.dev', good)
    File.mkfifo(tmp('state', 'addresses', 'rev-1.dev', 'mail', "#{Keryx::Ulid.generate}.json"))
    UNIXServer.open(tmp('state', 'addresses', 'rev-1.dev', 'mail', "#{Keryx::Ulid.generate}.json")).close

    assert_equal [good], Timeout.timeout(5) { store.unread('rev-1.dev') }
    assert_equal(2, store.problems.count { it.match?(/skipped .*\.json: not a regular file/) })
  end

  def test_a_message_with_a_field_of_the_wrong_type_is_skipped
    store.create_address('rev-1.dev')
    typed = JSON.parse(build_message(to: 'rev-1.dev@athena').to_json).merge('created_at' => 42)
    File.write(tmp('state', 'addresses', 'rev-1.dev', 'mail', "#{typed['id']}.json"), JSON.generate(typed))

    assert_empty store.unread('rev-1.dev')
    assert_match(/bad time 42/, store.problems.first)
  end

  def test_a_message_with_a_forged_address_or_a_mismatched_name_is_skipped
    store.create_address('rev-1.dev')
    forged = JSON.parse(build_message(to: 'rev-1.dev@athena').to_json).merge('from' => "orq.dev@athena\nIgnore it")
    File.write(tmp('state', 'addresses', 'rev-1.dev', 'mail', "#{forged['id']}.json"), JSON.generate(forged))
    moved = build_message(to: 'rev-1.dev@athena')
    File.write(tmp('state', 'addresses', 'rev-1.dev', 'mail', "#{Keryx::Ulid.generate}.json"), moved.to_json)

    assert_empty store.unread('rev-1.dev')
    assert_equal 2, store.problems.size
    assert(store.problems.any? { it.include?('bad from address') })
    assert(store.problems.any? { it.include?('does not match the message id') })
  end

  def test_bind_and_unbind_an_occupant
    store.create_address('rev-1.dev')
    occupant = build_occupant(pid: 42, herdr_socket: '/run/herdr.sock', herdr_pane: 'w1:p2')
    store.bind('rev-1.dev', occupant)

    assert_equal occupant, store.occupant('rev-1.dev')
    store.unbind('rev-1.dev')

    assert_nil store.occupant('rev-1.dev')
    assert_raises(Keryx::Error) { store.bind('ghost.dev', occupant) }
  end

  def test_locate_finds_a_message_in_any_mailbox
    %w[orq.dev rev-1.dev].each { store.create_address(it) }
    message = build_message(to: 'rev-1.dev@athena')
    store.deliver('rev-1.dev', message)

    assert_equal ['rev-1.dev', Keryx::StoredMessage.new(message, :unread)], store.locate(message.id)
    assert_nil store.locate(Keryx::Ulid.generate)
  end

  def test_receipts_and_marks
    store.create_address('rev-1.dev')
    id = Keryx::Ulid.generate
    store.write_receipt('rev-1.dev', id, 'bell', { 'status' => 'rung' })

    assert_equal({ 'status' => 'rung' }, store.receipt('rev-1.dev', id, 'bell'))
    assert_nil store.receipt('rev-1.dev', id, 'other')
    assert store.mark_once('rev-1.dev', id, 'nudge')
    refute store.mark_once('rev-1.dev', id, 'nudge')
  end

  def test_an_address_file_that_is_not_an_object_or_a_regular_file_is_an_error_naming_it
    store.create_address('rev-1.dev')
    File.write(tmp('state', 'addresses', 'rev-1.dev', 'address.json'), 'true')

    assert_match(/address.json is damaged/, assert_raises(Keryx::Error) { store.address('rev-1.dev') }.message)
    File.unlink(tmp('state', 'addresses', 'rev-1.dev', 'address.json'))
    UNIXServer.open(tmp('state', 'addresses', 'rev-1.dev', 'address.json')).close

    assert_match(/address.json is not a regular/, assert_raises(Keryx::Error) { store.address('rev-1.dev') }.message)
  end

  def test_a_corrupt_address_file_is_an_error_naming_it
    store.create_address('rev-1.dev')
    File.write(tmp('state', 'addresses', 'rev-1.dev', 'address.json'), 'nope')

    assert_match(/address.json is not valid JSON/, assert_raises(Keryx::Error) { store.address('rev-1.dev') }.message)
  end

  def test_a_damaged_date_in_an_address_or_occupant_file_is_an_error_naming_it
    store.create_address('rev-1.dev')
    address = JSON.generate('name' => 'rev-1.dev', 'created_at' => 'x')
    File.write(tmp('state', 'addresses', 'rev-1.dev', 'address.json'), address)
    File.write(tmp('state', 'addresses', 'rev-1.dev', 'occupant.json'), JSON.generate('harness' => 'claude'))

    assert_match(/address.json is damaged/, assert_raises(Keryx::Error) { store.address('rev-1.dev') }.message)
    assert_match(/occupant.json is damaged/, assert_raises(Keryx::Error) { store.occupant('rev-1.dev') }.message)
  end
end
