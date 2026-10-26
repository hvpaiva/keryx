# frozen_string_literal: true

require 'test_helper'

# keryx reads the store through no symbolic link, from below its root down to each file.
class StoreLinksTest < Minitest::Test
  include TempDir
  include Factory

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def elsewhere = @elsewhere ||= Keryx::Store.new(tmp('elsewhere'))

  def plant(to:)
    planted = build_message(to:, body: 'from outside the store')
    File.write(tmp('planted.json'), planted.to_json)
    File.symlink(tmp('planted.json'), tmp('state', 'addresses', to.split('@').first, 'mail', "#{planted.id}.json"))
    planted
  end

  def link_address(name)
    elsewhere.create_address(name)
    elsewhere.deliver(name, build_message(to: "#{name}@athena"))
    File.symlink(tmp('elsewhere', 'addresses', name), tmp('state', 'addresses', name))
    tmp('state', 'addresses', name)
  end

  # Puts in place of FOLDER of the address NAME a link to an empty folder outside the store.
  def link_out(name, folder)
    linked = tmp('state', 'addresses', name, folder)
    FileUtils.rm_rf(linked)
    FileUtils.mkdir_p(tmp('outside', name, folder))
    File.symlink(tmp('outside', name, folder), linked)
    linked
  end

  def test_a_mail_file_that_is_a_symbolic_link_is_skipped_as_not_a_regular_file
    store.create_address('rev-1.dev')
    good = build_message(to: 'rev-1.dev@athena')
    store.deliver('rev-1.dev', good)
    planted = plant(to: 'rev-1.dev@athena')

    assert_equal [good], store.unread('rev-1.dev')
    assert_raises(Keryx::Error) { store.find('rev-1.dev', planted.id) }
    linked = tmp('state', 'addresses', 'rev-1.dev', 'mail', "#{planted.id}.json")

    assert_equal ["skipped #{linked}: not a regular file"], store.problems.uniq
  end

  def test_an_address_folder_that_is_a_symbolic_link_is_no_address
    store.create_address('rev-1.dev')
    linked = link_address('ext.dev')

    assert_equal %w[rev-1.dev], store.address_names
    refute store.address?('ext.dev')
    assert_equal ["skipped #{linked}: a symbolic link"], store.problems.uniq
  end

  def test_an_address_folder_that_is_a_symbolic_link_takes_no_mail_and_no_join
    store.create_address('rev-1.dev')
    linked = link_address('ext.dev')

    assert_raises(Keryx::Error) { store.deliver('ext.dev', build_message(to: 'ext.dev@athena')) }
    error = assert_raises(Keryx::Error) { store.create_address('ext.dev') }
    assert_equal "#{linked} is a symbolic link", error.message
    assert_equal 1, Dir.children(tmp('elsewhere', 'addresses', 'ext.dev', 'mail')).size
  end

  def test_the_addresses_folder_as_a_symbolic_link_holds_no_address
    elsewhere.create_address('ext.dev')
    FileUtils.mkdir_p(tmp('state'))
    File.symlink(tmp('elsewhere', 'addresses'), tmp('state', 'addresses'))

    assert_empty store.address_names
    refute store.address?('ext.dev')
    assert_equal ["skipped #{tmp('state', 'addresses')}: a symbolic link"], store.problems.uniq
  end

  def test_a_mail_or_outgoing_folder_that_is_a_symbolic_link_lists_nothing
    store.create_address('rev-1.dev')
    elsewhere.create_address('rev-1.dev')
    elsewhere.deliver('rev-1.dev', build_message(to: 'rev-1.dev@athena'))
    elsewhere.displace('rev-1.dev', build_occupant(session: 'k7m2qp'))
    box = tmp('state', 'addresses', 'rev-1.dev')
    FileUtils.rm_rf(File.join(box, 'mail'))
    %w[mail outgoing].each { File.symlink(tmp('elsewhere', 'addresses', 'rev-1.dev', it), File.join(box, it)) }

    assert_empty store.stored('rev-1.dev')
    assert_empty store.unread('rev-1.dev')
    assert_empty store.outgoing('rev-1.dev')
    assert_equal(%w[mail outgoing].map { "skipped #{File.join(box, it)}: a symbolic link" }, store.problems.uniq)
  end

  def test_a_store_whose_root_is_a_symbolic_link_reads_as_any_other
    FileUtils.mkdir_p(tmp('real'))
    File.symlink(tmp('real'), tmp('linked'))
    linked = Keryx::Store.new(tmp('linked'))
    linked.create_address('rev-1.dev')
    message = build_message(to: 'rev-1.dev@athena')
    linked.deliver('rev-1.dev', message)

    assert_equal %w[rev-1.dev], linked.address_names
    assert_equal [message], linked.unread('rev-1.dev')
    assert_empty linked.problems
  end

  def test_history_reading_skips_what_a_symbolic_link_stands_for
    store.create_address('rev-1.dev')
    good = build_message(to: 'rev-1.dev@athena')
    store.deliver('rev-1.dev', good)
    planted = plant(to: 'rev-1.dev@athena')
    elsewhere.create_address('rev-1.dev')
    File.symlink(tmp('elsewhere', 'addresses', 'rev-1.dev'), tmp('state', 'addresses', 'rev'))
    archive = Keryx::Archive.new(store, old: true)

    assert_equal [good], archive.held('rev-1.dev').map(&:message)
    refute archive.old?('rev')
    assert_equal([good], archive.sent_by('orq.dev@athena').map(&:message))
    linked = tmp('state', 'addresses', 'rev-1.dev', 'mail', "#{planted.id}.json")

    assert_includes store.problems, "skipped #{linked}: not a regular file"
  end

  def test_no_message_is_written_through_a_linked_tmp_or_mail_folder
    %w[rev-1.dev rev-2.dev].each { store.create_address(it) }
    linked = [link_out('rev-1.dev', 'tmp'), link_out('rev-2.dev', 'mail')]
    errors = %w[rev-1.dev rev-2.dev].map do |name|
      assert_raises(Keryx::Error) { store.deliver(name, build_message(to: "#{name}@athena")) }
    end

    assert_equal(linked.map { "#{it} is a symbolic link" }, errors.map(&:message))
    assert_empty Dir.glob('*/*/*', base: tmp('outside'))
  end

  def test_no_receipt_or_mark_is_written_through_a_linked_folder
    store.create_address('rev-1.dev')
    link_out('rev-1.dev', 'receipts')
    id = Keryx::Ulid.generate

    assert_raises(Keryx::Error) { store.write_receipt('rev-1.dev', id, 'bell', { 'status' => 'rung' }) }
    assert_raises(Keryx::Error) { store.claim('rev-1.dev', id, 'claim', 'first') }
    assert_raises(Keryx::Error) { store.mark_once('rev-1.dev', id, 'hook') }
    assert_empty Dir.glob('*/*/*', base: tmp('outside'))
  end

  def test_nothing_is_queued_through_a_linked_host_folder
    FileUtils.mkdir_p([tmp('state', 'outbox'), tmp('outside')])
    File.symlink(tmp('outside'), tmp('state', 'outbox', 'zeus'))
    message = build_message(to: 'port.dev@zeus')

    error = assert_raises(Keryx::Error) { store.outbox.queue('zeus', message) }
    assert_equal "#{tmp('state', 'outbox', 'zeus')} is a symbolic link", error.message
    assert_raises(Keryx::Error) { store.outbox.queue_in_thread('zeus', message.thread) { message } }
    assert_empty Dir.children(tmp('outside'))
  end

  def test_a_lock_file_that_is_a_symbolic_link_is_refused_and_its_target_never_made
    FileUtils.mkdir_p(tmp('state', 'outbox', 'zeus'))
    locks = [tmp('state', 'occupants.lock'), tmp('state', 'outbox', 'zeus', 'thread.lock'),
             tmp('state', 'outbox', 'zeus', 'outcomes.lock')]
    locks.each_with_index { |lock, index| File.symlink(tmp("target-#{index}"), lock) }
    message = build_message(to: 'port.dev@zeus')
    store.outbox.queue('zeus', message)
    store.outbox.write_outcome('zeus', message.id, { 'status' => 'queued' })
    errors = [-> { store.with_occupants_lock { nil } },
              -> { store.outbox.queue_in_thread('zeus', message.thread) { message } },
              -> { store.outbox.write_outcome('zeus', message.id, { 'status' => 'forwarded' }) }]
             .map { |attempt| assert_raises(Keryx::Error, &attempt) }

    assert_equal(locks.map { "#{it} is a symbolic link" }, errors.map(&:message))
    assert_equal [false] * 3, Array.new(3) { File.exist?(tmp("target-#{it}")) }
  end
end
