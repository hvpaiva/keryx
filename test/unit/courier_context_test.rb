# frozen_string_literal: true

require 'test_helper'

class CourierContextTest < Minitest::Test
  include TempDir
  include Factory
  include CourierHelpers

  def impl(ceiling: 125_000, **fields)
    store.create_address('impl')
    build_occupant(session_id: 'session-impl', ceiling:, **fields).tap { store.bind('impl', it) }
  end

  def told = ->(round) { round.context.map { [it.recipient, it.stage] } }

  def bodies(name) = store.unread(name).select { it.from == 'keryx@athena' }.map(&:body)

  def test_a_session_and_its_director_are_told_once_near_the_ceiling_and_once_at_it
    impl(director: 'orq')
    meter.figures['session-impl'] = 99_999

    assert_empty courier.round.context
    meter.figures['session-impl'] = 100_000

    assert_equal [['impl@athena', :near], ['orq@athena', :near]], told.call(courier.round)
    assert_empty courier.round.context
    meter.figures['session-impl'] = 126_000

    assert_equal [['impl@athena', :ceiling], ['orq@athena', :ceiling]], told.call(courier.round)
    assert_empty courier.round.context
  end

  def test_a_notice_says_the_figure_the_ceiling_and_to_reach_a_stopping_point
    impl(director: 'orq')
    [100_000, 126_000].each do |used|
      meter.figures['session-impl'] = used
      courier.round
    end

    assert_equal ['impl@athena has 100k tokens of context in use, 80% of its 125k ceiling. It should reach a ' \
                  'stopping point.',
                  'impl@athena has 126k tokens of context in use, 101% of its 125k ceiling. It reached its ceiling ' \
                  'and should reach a stopping point now.'], bodies('orq').sort
    assert_equal bodies('orq').sort, bodies('impl').sort
    assert(store.unread('orq').none?(&:context))
  end

  def test_a_session_first_seen_past_its_ceiling_is_never_told_it_nears_it
    impl
    meter.figures['session-impl'] = 130_000

    assert_equal [['impl@athena', :ceiling]], told.call(courier.round)
    meter.figures['session-impl'] = 110_000

    assert_empty courier.round.context
  end

  def test_a_refresh_tells_nothing_again_but_a_new_join_or_another_ceiling_does
    occupant = impl
    meter.figures['session-impl'] = 110_000
    courier.round
    store.bind('impl', occupant.with(pid: 77))

    assert_empty courier.round.context
    store.bind('impl', occupant.with(ceiling: 120_000))

    assert_equal [['impl@athena', :near]], told.call(courier.round)
    store.bind('impl', occupant.with(joined_at: LATER))

    assert_equal [['impl@athena', :near]], told.call(courier.round)
  end

  def test_without_a_director_the_sender_of_the_oldest_open_request_is_told
    impl
    older = build_message(to: 'impl@athena', from: 'rev-1@athena', kind: 'request', id: Keryx::Ulid.generate(NOW))
    newer = build_message(to: 'impl@athena', from: 'orq@athena', kind: 'request', id: Keryx::Ulid.generate(NOW + 1))
    [newer, older].each { store.deliver('impl', it) }
    meter.figures['session-impl'] = 100_000

    assert_equal %w[impl@athena rev-1@athena], courier.round.context.map(&:recipient)
    store.deliver('rev-1', build_message(to: 'rev-1@athena', from: 'impl@athena', kind: 'reply',
                                         in_reply_to: older.id, thread: older.thread))
    meter.figures['session-impl'] = 125_000

    assert_equal %w[impl@athena orq@athena], courier.round.context.map(&:recipient)
  end

  def test_a_session_alone_or_its_own_director_is_told_once
    impl(director: 'impl')
    meter.figures['session-impl'] = 125_000

    assert_equal [['impl@athena', :ceiling]], told.call(courier.round)
    assert_equal 1, bodies('impl').size
  end

  def test_a_notice_a_director_did_not_get_is_sent_to_it_alone_on_the_next_round
    impl(director: 'orq')
    meter.figures['session-impl'] = 100_000
    original = postman.method(:post)
    failures = [Errno::ENOSPC.new('mail')]
    postman.define_singleton_method(:post) do |**args|
      raise failures.shift if args[:recipient].name == 'orq' && failures.any?

      original.call(**args)
    end
    first = courier.round

    assert_equal [[['impl@athena', :near]], 1], [told.call(first), first.errors.size]
    assert_match(/could not tell orq@athena about the context of impl@athena; .*mail/, first.errors.first)
    assert_equal [['orq@athena', :near]], told.call(courier.round)
    assert_equal [1, 1], [bodies('impl').size, bodies('orq').size]
  end

  def test_a_notice_whose_mark_was_not_kept_is_not_stored_again
    impl(director: 'orq')
    meter.figures['session-impl'] = 100_000
    original = store.method(:mark_once)
    failures = [Errno::ENOSPC.new('receipts')]
    store.define_singleton_method(:mark_once) do |name, id, kind|
      raise failures.shift if kind == 'context' && failures.any?

      original.call(name, id, kind)
    end
    first = courier.round

    assert_equal [[['orq@athena', :near]], 1], [told.call(first), first.errors.size]
    assert_equal [['impl@athena', :near]], told.call(build_courier.round)
    assert_equal [1, 1], [bodies('impl').size, bodies('orq').size]
  end

  def test_two_couriers_that_tell_the_same_notice_at_once_store_it_once
    impl
    meter.figures['session-impl'] = 100_000
    other = build_courier
    interleaved = nil
    original = postman.method(:post)
    # The other courier runs its whole round between this one's claim of the id and its post.
    postman.define_singleton_method(:post) do |**args|
      unless interleaved
        interleaved = :running
        interleaved = other.round
      end
      original.call(**args)
    end
    first = courier.round

    assert_equal [[], [], [['impl@athena', :near]]], [first.errors, told.call(first), told.call(interleaved)]
    assert_equal 1, bodies('impl').size
  end

  # The meter binds the address to what replacement returns as it reads the session.
  def bound_while_read(replacement)
    box = store
    meter.define_singleton_method(:read) do |measured|
      box.bind('impl', replacement.call)
      figures[measured.session_id]&.then { Keryx::Context.new(used: it, window: nil) }
    end
  end

  def test_a_figure_read_while_another_session_joined_or_the_ceiling_changed_is_dropped
    occupant = impl(director: 'orq')
    meter.figures['session-impl'] = 100_000
    replacement = nil
    bound_while_read(-> { replacement })
    [occupant.with(session_id: 'session-new', joined_at: LATER), occupant.with(ceiling: 500_000)].each do |other|
      store.bind('impl', occupant)
      replacement = other
      round = courier.round

      assert_equal [[], []], [round.context, round.errors]
    end
    assert_empty bodies('impl') + bodies('orq')
  end

  def test_a_figure_read_while_the_session_recorded_its_process_again_is_told
    occupant = impl
    meter.figures['session-impl'] = 100_000
    bound_while_read(-> { occupant.with(pid: 77) })

    assert_equal [['impl@athena', :near]], told.call(courier.round)
  end

  def test_sessions_without_a_ceiling_or_that_ended_are_not_read
    impl(ceiling: nil)
    store.create_address('docs')
    store.bind('docs', build_occupant(session_id: 'session-docs', pid: 999, started: 'started 999', ceiling: 1000))
    meter.figures.merge!('session-impl' => 900_000, 'session-docs' => 900_000)

    assert_empty courier.round.context
    assert_empty meter.reads
  end
end
