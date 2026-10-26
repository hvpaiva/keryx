# frozen_string_literal: true

require 'test_helper'
require 'socket'
require 'timeout'

class ReceiptTest < Minitest::Test
  include TempDir
  include Factory

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def setup
    super
    store.create_address('rev-1.dev')
  end

  def bell_receipt(id) = tmp('state', 'addresses', 'rev-1.dev', 'receipts', "#{id}.bell")

  def receipts = tmp('state', 'addresses', 'rev-1.dev', 'receipts')

  def test_a_receipt_outside_its_schema_is_ignored_and_reported
    ids = Array.new(3) { Keryx::Ulid.generate }
    ['[]', '{"status": 42}', '{"status": "rung", "detail": []}'].zip(ids).each do |text, id|
      File.write(bell_receipt(id), text)
    end

    assert_equal([nil] * 3, ids.map { store.receipt('rev-1.dev', it, 'bell') })
    assert_match(/#{ids[0]}\.bell is not a JSON object; it is ignored until keryx writes it again/, store.problems[0])
    assert_match(/#{ids[1]}\.bell has a bad status/, store.problems[1])
    assert_match(/#{ids[2]}\.bell has a bad detail/, store.problems[2])
  end

  def test_a_bell_receipt_whose_obstacle_or_evidence_is_not_a_string_is_ignored_and_reported
    deferred = { 'status' => 'deferred', 'channel' => 'herdr', 'obstacle' => 'dialog', 'evidence' => 'Do you trust' }
    written = [deferred, deferred.merge('obstacle' => 42), deferred.merge('evidence' => %w[Do you trust])]
    ids = Array.new(3) { Keryx::Ulid.generate }
    written.zip(ids).each { |receipt, id| File.write(bell_receipt(id), JSON.generate(receipt)) }

    assert_equal([deferred, nil, nil], ids.map { store.receipt('rev-1.dev', it, 'bell') })
    assert_match(/#{ids[1]}\.bell has a bad obstacle/, store.problems[0])
    assert_match(/#{ids[2]}\.bell has a bad evidence/, store.problems[1])
  end

  def test_a_receipt_that_is_not_a_regular_file_is_ignored_without_waiting_on_it
    id = Keryx::Ulid.generate
    File.mkfifo(bell_receipt(id))

    assert_nil Timeout.timeout(5) { store.receipt('rev-1.dev', id, 'bell') }
    assert_match(/#{id}\.bell is not a regular file; it is ignored/, store.problems.first)
  end

  def test_a_socket_in_place_of_a_receipt_is_ignored
    id = Keryx::Ulid.generate
    UNIXServer.open(bell_receipt(id)).close

    assert_nil store.receipt('rev-1.dev', id, 'bell')
    assert_match(/#{id}\.bell is not a regular file; it is ignored/, store.problems.first)
  end

  def test_a_forward_receipt_with_bad_attempts_is_ignored_and_reported
    message = build_message(to: 'port.dev@zeus')
    store.outbox.queue('zeus', message)
    store.outbox.write_receipt('zeus', message.id, { 'status' => 'queued', 'attempts' => [] })

    assert_nil store.outbox.receipt('zeus', message.id)
    assert_match(/#{message.id}\.forward has a bad attempts/, store.problems.first)
  end

  def test_a_receipt_is_written_again_over_a_damaged_one
    id = Keryx::Ulid.generate
    File.write(bell_receipt(id), '[]')
    store.write_receipt('rev-1.dev', id, 'bell', { 'status' => 'rung' })

    assert_equal({ 'status' => 'rung' }, store.receipt('rev-1.dev', id, 'bell'))
  end

  def test_the_first_claim_stays_and_one_that_is_not_a_regular_file_is_an_error
    id = Keryx::Ulid.generate
    claims = %w[first second].map { store.claim('rev-1.dev', id, 'claim', it) }

    assert_equal %w[first first], claims
    FileUtils.mkdir(tmp('state', 'addresses', 'rev-1.dev', 'receipts', "#{id}.folder"))
    error = assert_raises(Keryx::Error) { store.claim('rev-1.dev', id, 'folder', 'first') }

    assert_match(/#{id}\.folder is not a regular file/, error.message)
  end

  def test_a_claimed_value_the_block_rejects_is_damaged
    id = Keryx::Ulid.generate
    store.claim('rev-1.dev', id, 'claim', 'first')

    assert_equal 'first', store.claimed('rev-1.dev', id, 'claim') { it == 'first' }
    error = assert_raises(Keryx::Store::Damaged) { store.claimed('rev-1.dev', id, 'claim') { it == 'second' } }
    assert_equal "#{receipts}/#{id}.claim is damaged", error.message
    assert_raises(Keryx::Store::Damaged) { store.claim('rev-1.dev', id, 'claim', 'third') { it == 'third' } }
  end

  def test_a_claim_written_over_is_what_the_next_claim_reads_back
    id = Keryx::Ulid.generate
    store.claim('rev-1.dev', id, 'claim', 'damaged')

    assert_equal 'fresh', store.reclaim('rev-1.dev', id, 'claim', 'fresh')
    assert_equal 'fresh', store.claim('rev-1.dev', id, 'claim', 'later')
  end

  def test_each_damaged_claim_of_a_kind_is_a_problem_and_a_mailbox_without_receipts_has_none
    sound, damaged, other, folder = Array.new(4) { Keryx::Ulid.generate(Time.now + it) }
    { sound => 'sound', damaged => 'damaged' }.each { |id, value| store.claim('rev-1.dev', id, 'claim', value) }
    store.claim('rev-1.dev', other, 'other', 'damaged')
    FileUtils.mkdir("#{receipts}/#{folder}.claim")
    store.report_damaged_claims('rev-1.dev', 'claim') { it == 'sound' }

    assert_equal ["#{receipts}/#{damaged}.claim is damaged", "#{receipts}/#{folder}.claim is not a regular file"],
                 store.problems
    FileUtils.rm_rf(receipts)
    store.report_damaged_claims('rev-1.dev', 'claim') { false }

    assert_equal 2, store.problems.size
  end

  def test_a_receipt_or_claim_that_is_a_symbolic_link_is_not_a_regular_file
    File.write(tmp('outside'), JSON.generate('status' => 'rung'))
    bell, claim = Array.new(2) { Keryx::Ulid.generate }
    File.symlink(tmp('outside'), bell_receipt(bell))
    File.symlink(tmp('outside'), "#{receipts}/#{claim}.claim")

    assert_nil store.receipt('rev-1.dev', bell, 'bell')
    assert_equal ["#{bell_receipt(bell)} is not a regular file; it is ignored until keryx writes it again"],
                 store.problems
    error = assert_raises(Keryx::Error) { store.claimed('rev-1.dev', claim, 'claim') }
    assert_equal "#{receipts}/#{claim}.claim is not a regular file", error.message
  end

  def test_a_receipts_folder_that_is_a_symbolic_link_is_neither_read_nor_listed
    elsewhere = Keryx::Store.new(tmp('elsewhere'))
    elsewhere.create_address('rev-1.dev')
    id = Keryx::Ulid.generate
    elsewhere.write_receipt('rev-1.dev', id, 'bell', { 'status' => 'rung' })
    elsewhere.claim('rev-1.dev', id, 'claim', 'damaged')
    FileUtils.rm_rf(receipts)
    File.symlink(tmp('elsewhere', 'addresses', 'rev-1.dev', 'receipts'), receipts)

    assert_nil store.receipt('rev-1.dev', id, 'bell')
    assert_raises(Keryx::Error) { store.claimed('rev-1.dev', id, 'claim') }
    store.report_damaged_claims('rev-1.dev', 'claim') { false }

    assert_equal ["skipped #{receipts}: a symbolic link"], store.problems.uniq
  end
end
