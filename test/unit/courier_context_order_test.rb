# frozen_string_literal: true

require 'test_helper'

class CourierContextOrderTest < Minitest::Test
  include TempDir
  include Factory
  include CourierHelpers

  # What the recipient gets reading its oldest unread message until none is left, as keryx read does.
  def read_in_order(name)
    Array.new(store.unread(name).size) do
      store.unread(name).first.tap { store.mark_read(name, it.id) }.body.split[2]
    end
  end

  def mailbox(name) = store.mailbox(name).map { it.message.body.split[2] }

  # A courier as another process runs it, with its own store, meter and clock; waits hears each time it waits for the
  # occupants lock.
  def other_courier(figure, clock, waits)
    box = Keryx::Store.new(tmp('state'), sleeper: ->(seconds) { sleep(seconds.tap { waits << it }) })
    mail = Keryx::Postman.new(store: box, bell: QuietBell.new, forwarder: nil, host: 'athena', clock:,
                              person: 'person')
    build_courier(clock:, measure: Meter.new.tap { it.figures['session-impl'] = figure }, box:, mail:)
  end

  # Once this courier claims the id of a notice, the other one runs its round in a thread, and this one goes on when
  # that round ends or waits for the occupants lock.
  def alongside_the_claim(other, waits, threads = [])
    original = store.method(:claim)
    store.define_singleton_method(:claim) do |*args|
      threads << Thread.new { other.round } if threads.empty?
      sleep(0.01) while threads.first.alive? && waits.empty?
      original.call(*args)
    end
    threads
  end

  def test_a_notice_near_the_ceiling_never_sorts_after_the_ceiling_notice_another_courier_was_telling
    impl
    meter.figures['session-impl'] = 126_000
    waits = []
    threads = alongside_the_claim(other_courier(100_000, -> { LATER + 1 }, waits), waits)
    ceiling = courier.round
    near = threads.first.value

    assert_equal [[], [], [['impl@athena', :ceiling]]], [ceiling.errors, near.errors, told.call(ceiling)]
    assert_includes [%w[126k], %w[100k 126k]], mailbox('impl')
    assert_equal mailbox('impl'), read_in_order('impl')
  end

  def test_a_ceiling_notice_sorts_after_the_notice_near_it_when_the_clock_steps_back_between_them
    impl
    time = LATER
    stepping = build_courier(clock: -> { time })
    meter.figures['session-impl'] = 100_000
    stepping.round
    time -= 3600
    meter.figures['session-impl'] = 126_000

    assert_equal [['impl@athena', :ceiling]], told.call(stepping.round)
    assert_equal [%w[100k 126k]] * 2, [mailbox('impl'), read_in_order('impl')]
  end

  # Tells the notice near the ceiling, writes over the id claimed for it what the block makes of that id, and runs
  # the round that reaches the ceiling.
  def round_past_a_damaged_near_claim
    impl
    meter.figures['session-impl'] = 100_000
    courier.round
    claims = Dir[tmp('state', 'addresses', 'impl', 'receipts', '*.context-id')]
    File.write(claims.first, yield(File.read(claims.first)))
    meter.figures['session-impl'] = 126_000
    [claims, courier.round]
  end

  # The order of the two notices can no longer be proved, and losing it costs less than losing the ceiling notice.
  def assert_the_ceiling_notice_goes_out_with_a_fresh_id(&)
    claims, round = round_past_a_damaged_near_claim(&)

    assert_equal [1, [['impl@athena', :ceiling]]], [claims.size, told.call(round)]
    assert_equal %w[100k 126k], mailbox('impl').sort
    assert_equal ["#{claims.first} is damaged"], store.problems
    assert_equal ['the ceiling notice of impl@athena to impl@athena takes a fresh id and may sort before the notice ' \
                  "near it; #{claims.first} is damaged"], round.errors
    assert_equal([[], []], courier.round.then { [it.context, it.errors] })
  end

  def test_an_empty_claim_of_the_notice_near_the_ceiling_holds_no_ceiling_notice_back
    assert_the_ceiling_notice_goes_out_with_a_fresh_id { '' }
  end

  def test_a_truncated_claim_of_the_notice_near_the_ceiling_holds_no_ceiling_notice_back
    assert_the_ceiling_notice_goes_out_with_a_fresh_id { it[0, 13] }
  end

  def test_a_claim_of_the_notice_near_the_ceiling_that_is_no_id_holds_no_ceiling_notice_back
    assert_the_ceiling_notice_goes_out_with_a_fresh_id { 'not-json' }
  end
end
