# frozen_string_literal: true

require 'test_helper'

# The record of the dialog last told for a join: a read that another courier's change overtook, the holds a screen
# with no dialog takes, and a record or a round that broke off. Adapted from dialog_contract_probe.rb, rev-54's probe
# in its review of pull request #42.
class CourierDialogRecordTest < Minitest::Test
  include TempDir
  include Factory
  include CourierHelpers

  SOCKET = '/h.sock'
  PANE = 'w1:p2'
  FREE = "\u2022 Done.\n\n\u276f \n"
  class Stop < StandardError; end

  def member(director: 'orq.dev', **fields)
    store.create_address('impl.dev')
    fake_herdr.put(SOCKET, PANE, Keryx::Herdr::Agent.new(pane: PANE, kind: 'claude', status: 'blocked'))
    build_occupant(session_id: 'session-impl', session: 'abc123', herdr_socket: SOCKET, herdr_pane: PANE, director:,
                   **fields).tap { store.bind('impl.dev', it) }
  end

  def show(screen) = fake_herdr.views[[SOCKET, PANE]] = screen

  def write = Screens.real('claude-write')

  def hooks = Screens.real('codex-hooks')

  def notices = store.unread('orq.dev').select { it.from == 'keryx.system@athena' }

  # The first line each notice quotes, which names its dialog, sorted, since every courier here draws its ids at one
  # instant and their order is random.
  def told = notices.map { |notice| notice.body.lines.find { it.start_with?('  ') }.strip }.sort

  def receipts(kind) = Dir[tmp('state', 'addresses', 'impl.dev', 'receipts', "*.#{kind}")]

  def record_of(occupant)
    mark = Keryx::Ulid.derive(occupant.joined_at, "dialog orq.dev@athena #{Keryx::Courier.join_of(occupant)}")
    tmp('state', 'addresses', 'impl.dev', 'receipts', "#{mark}.#{Keryx::DialogNotice::SHOWN}")
  end

  # Each hold of the occupants lock the store takes, as :hold, and each read of a dialog record, as :read outside a
  # hold or :read_held inside one.
  def watch
    log = []
    held = [false]
    watch_holds(log, held)
    watch_reads(log, held)
    log
  end

  def watch_holds(log, held)
    lock = store.method(:with_occupants_lock)
    store.define_singleton_method(:with_occupants_lock) do |**options, &block|
      log << :hold
      lock.call(**options) do
        held[0] = true
        block.call
      ensure
        held[0] = false
      end
    end
  end

  def watch_reads(log, held)
    read = store.method(:claimed)
    store.define_singleton_method(:claimed) do |name, id, kind, &check|
      log << (held[0] ? :read_held : :read) if kind == Keryx::DialogNotice::SHOWN
      read.call(name, id, kind, &check)
    end
  end

  # While this round reads the pane, one courier tells the dialog it reads and another the dialog after it, so this
  # round's read is older than the record it finds in the hold.
  def test_a_read_older_than_the_record_another_courier_wrote_tells_nothing
    member
    show(lambda do
      show(write)
      build_courier.round
      show(hooks)
      build_courier.round
      write
    end)

    assert_equal [[], []], [courier.round.dialogs, courier.round.dialogs]
    assert_equal ['Create file', 'Hooks need review'], told
  end

  def test_a_read_of_the_dialog_told_before_tells_nothing_once_another_courier_told_the_next
    member
    show(write)
    courier.round
    show(lambda do
      show(hooks)
      build_courier.round
      write
    end)

    assert_equal [[], []], [build_courier.round.dialogs, build_courier.round.dialogs]
    assert_equal ['Create file', 'Hooks need review'], told
  end

  def test_a_free_read_older_than_the_record_another_courier_wrote_keeps_that_record
    member
    show(write)
    courier.round
    show(lambda do
      show(hooks)
      build_courier.round
      FREE
    end)

    assert_equal [[], []], [build_courier.round.dialogs, build_courier.round.dialogs]
    assert_equal ['Create file', 'Hooks need review'], told
  end

  def test_a_screen_with_no_dialog_and_no_record_takes_no_hold
    member
    show(FREE)
    log = watch
    round = courier.round

    assert_equal [0, [], []], [log.count(:hold), round.errors, receipts(Keryx::DialogNotice::SHOWN)]
  end

  def test_a_screen_with_no_dialog_removes_the_record_in_one_hold_that_reads_it_again
    member
    show(write)
    courier.round
    show(FREE)
    log = watch
    round = courier.round

    assert_equal [%i[read hold read_held], [], []], [log, round.errors, receipts(Keryx::DialogNotice::SHOWN)]
    show(write)

    assert_equal 1, courier.round.dialogs.size
    assert_equal ['Create file', 'Create file'], told
  end

  def test_a_record_that_does_not_parse_is_written_over_and_reported_once
    path = record_of(member)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, 'broken record')
    show(write)
    rounds = Array.new(3) { courier.round }

    assert_equal([[1, 1], [0, 0], [0, 0]], rounds.map { [it.dialogs.size, it.errors.size] })
    assert_equal ["the dialog notice of impl.dev@athena writes over its damaged record; #{path} is damaged"],
                 rounds.first.errors
    assert_match Keryx::DialogNotice::RECORD, File.read(path)
    assert_equal ['Create file'], told
  end

  # The second join shares the first one's instant and harness, and the third comes a second later.
  def test_a_new_join_is_told_the_dialog_the_join_before_it_was_told
    member
    show(write)
    courier.round
    member(session: 'def456')
    second = courier.round
    member(session: 'ghi789', joined_at: NOW + 1)
    third = courier.round

    assert_equal [1, 1], [second.dialogs.size, third.dialogs.size]
    assert_equal [3, 3], [told.size, receipts(Keryx::DialogNotice::SHOWN).size]
  end

  def test_a_round_stopped_between_the_post_and_the_mark_neither_loses_nor_doubles_the_notice
    member
    show(write)
    mail = postman
    stopping = Object.new
    stopping.define_singleton_method(:post) { |**fields| mail.post(**fields).tap { raise Stop } }

    assert_raises(Stop) { build_courier(mail: stopping).round }
    posted = notices.map(&:id)

    assert_equal [1, []], [posted.size, receipts(Keryx::DialogNotice::TOLD)]
    assert_equal [1, 0], [courier.round.dialogs.size, courier.round.dialogs.size]
    assert_equal [posted, 1], [notices.map(&:id), receipts(Keryx::DialogNotice::TOLD).size]
  end
end
