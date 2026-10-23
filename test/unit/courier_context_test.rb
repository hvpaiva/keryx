# frozen_string_literal: true

require 'test_helper'

class CourierContextTest < Minitest::Test
  include TempDir
  include Factory
  include CourierHelpers

  def bodies(name) = store.unread(name).select { it.from == 'keryx.system@athena' }.map(&:body)

  def test_a_session_and_its_director_are_told_once_near_the_ceiling_and_once_at_it
    impl(director: 'orq.dev')
    meter.figures['session-impl'] = 99_999

    assert_empty courier.round.context
    meter.figures['session-impl'] = 100_000

    assert_equal [['impl.dev@athena', :near], ['orq.dev@athena', :near]], told.call(courier.round)
    assert_empty courier.round.context
    meter.figures['session-impl'] = 126_000

    assert_equal [['impl.dev@athena', :ceiling], ['orq.dev@athena', :ceiling]], told.call(courier.round)
    assert_empty courier.round.context
  end

  def test_a_notice_says_the_figure_the_ceiling_and_to_reach_a_stopping_point
    impl(director: 'orq.dev')
    [100_000, 126_000].each do |used|
      meter.figures['session-impl'] = used
      courier.round
    end

    assert_equal ['impl.dev@athena has 100k tokens of context in use, 80% of its 125k ceiling. It should reach a ' \
                  'stopping point.',
                  'impl.dev@athena has 126k tokens of context in use, 101% of its 125k ceiling. It reached its ' \
                  'ceiling and should reach a stopping point now.'], bodies('orq.dev').sort
    assert_equal bodies('orq.dev').sort, bodies('impl.dev').sort
    assert(store.unread('orq.dev').none?(&:context))
  end

  def test_a_session_first_seen_past_its_ceiling_is_never_told_it_nears_it
    impl
    meter.figures['session-impl'] = 130_000

    assert_equal [['impl.dev@athena', :ceiling]], told.call(courier.round)
    meter.figures['session-impl'] = 110_000

    assert_empty courier.round.context
  end

  def test_a_refresh_tells_nothing_again_but_a_new_join_or_another_ceiling_does
    occupant = impl
    meter.figures['session-impl'] = 110_000
    courier.round
    store.bind('impl.dev', occupant.with(pid: 77))

    assert_empty courier.round.context
    store.bind('impl.dev', occupant.with(ceiling: 120_000))

    assert_equal [['impl.dev@athena', :near]], told.call(courier.round)
    store.bind('impl.dev', occupant.with(joined_at: LATER))

    assert_equal [['impl.dev@athena', :near]], told.call(courier.round)
  end

  def test_without_a_director_the_sender_of_the_oldest_open_request_is_told
    impl
    older = build_message(to: 'impl.dev@athena', from: 'rev-1.dev@athena', kind: 'request', id: Keryx::Ulid.generate(NOW))
    newer = build_message(to: 'impl.dev@athena', from: 'orq.dev@athena', kind: 'request',
                          id: Keryx::Ulid.generate(NOW + 1))
    [newer, older].each { store.deliver('impl.dev', it) }
    meter.figures['session-impl'] = 100_000

    assert_equal %w[impl.dev@athena rev-1.dev@athena], courier.round.context.map(&:recipient)
    store.deliver('rev-1.dev', build_message(to: 'rev-1.dev@athena', from: 'impl.dev@athena', kind: 'reply',
                                             in_reply_to: older.id, thread: older.thread))
    meter.figures['session-impl'] = 125_000

    assert_equal %w[impl.dev@athena orq.dev@athena], courier.round.context.map(&:recipient)
  end

  def test_a_session_alone_or_its_own_director_is_told_once
    impl(director: 'impl.dev')
    meter.figures['session-impl'] = 125_000

    assert_equal [['impl.dev@athena', :ceiling]], told.call(courier.round)
    assert_equal 1, bodies('impl.dev').size
  end

  def test_a_notice_a_director_did_not_get_is_sent_to_it_alone_on_the_next_round
    impl(director: 'orq.dev')
    meter.figures['session-impl'] = 100_000
    original = postman.method(:post)
    failures = [Errno::ENOSPC.new('mail')]
    postman.define_singleton_method(:post) do |**args|
      raise failures.shift if args[:recipient].key == 'orq.dev' && failures.any?

      original.call(**args)
    end
    first = courier.round

    assert_equal [[['impl.dev@athena', :near]], 1], [told.call(first), first.errors.size]
    assert_match(/could not tell orq.dev@athena about the context of impl.dev@athena; .*mail/, first.errors.first)
    assert_equal [['orq.dev@athena', :near]], told.call(courier.round)
    assert_equal [1, 1], [bodies('impl.dev').size, bodies('orq.dev').size]
  end

  def test_a_notice_whose_mark_was_not_kept_is_not_stored_again
    impl(director: 'orq.dev')
    meter.figures['session-impl'] = 100_000
    original = store.method(:mark_once)
    failures = [Errno::ENOSPC.new('receipts')]
    store.define_singleton_method(:mark_once) do |name, id, kind|
      raise failures.shift if kind == 'context' && failures.any?

      original.call(name, id, kind)
    end
    first = courier.round

    assert_equal [[['orq.dev@athena', :near]], 1], [told.call(first), first.errors.size]
    assert_equal [['impl.dev@athena', :near]], told.call(build_courier.round)
    assert_equal [1, 1], [bodies('impl.dev').size, bodies('orq.dev').size]
  end

  def test_two_couriers_that_tell_the_same_notice_at_once_store_it_once
    impl
    meter.figures['session-impl'] = 100_000
    other = build_courier
    interleaved = nil
    original = postman.method(:post)
    # The other courier runs its whole round between this one's check of the mark and its post.
    postman.define_singleton_method(:post) do |**args|
      unless interleaved
        interleaved = :running
        interleaved = other.round
      end
      original.call(**args)
    end
    first = courier.round

    assert_equal [[], [], [['impl.dev@athena', :near]]], [first.errors, told.call(first), told.call(interleaved)]
    assert_equal 1, bodies('impl.dev').size
  end

  # The first post runs step before it, as another courier or a join acting between the checks and the post would.
  def before_first_post(&step)
    original = postman.method(:post)
    steps = [step]
    postman.define_singleton_method(:post) do |**args|
      steps.shift&.call
      original.call(**args)
    end
  end

  def figures_told(name) = bodies(name).map { it.split[2] }

  def test_a_notice_near_the_ceiling_is_not_sent_once_another_courier_sent_the_ceiling
    impl(director: 'orq.dev')
    meter.figures['session-impl'] = 100_000
    second = nil
    before_first_post do
      meter.figures['session-impl'] = 126_000
      second = build_courier.round
    end
    first = courier.round

    assert_equal [[], [], [['impl.dev@athena', :ceiling], ['orq.dev@athena', :ceiling]]],
                 [first.errors, told.call(first), told.call(second)]
    assert_equal [['126k'], ['126k']], [figures_told('impl.dev'), figures_told('orq.dev')]
  end

  def test_a_session_that_joined_after_the_check_is_not_told_the_figure_of_the_one_before
    occupant = impl(director: 'orq.dev')
    meter.figures['session-impl'] = 100_000
    before_first_post do
      store.with_occupants_lock { store.bind('impl.dev', occupant.with(session_id: 'session-new', joined_at: LATER)) }
    end
    round = courier.round

    assert_equal [[], []], [round.context, round.errors]
    assert_empty bodies('impl.dev') + bodies('orq.dev')
  end

  def test_a_ceiling_notice_claimed_and_not_yet_marked_keeps_the_notice_near_it_back
    impl
    meter.figures['session-impl'] = 126_000
    original = store.method(:deliver)
    failures = [Errno::ENOSPC.new('mail')]
    store.define_singleton_method(:deliver) do |name, message|
      raise failures.shift if failures.any?

      original.call(name, message)
    end

    assert_equal 1, courier.round.errors.size
    meter.figures['session-impl'] = 100_000
    near = courier.round

    assert_equal [[], [], []], [near.context, near.errors, bodies('impl.dev')]
    meter.figures['session-impl'] = 126_000

    assert_equal [['impl.dev@athena', :ceiling]], told.call(courier.round)
  end

  # The meter binds the address to what replacement returns as it reads the session.
  def bound_while_read(replacement)
    box = store
    meter.define_singleton_method(:read) do |measured|
      box.bind('impl.dev', replacement.call)
      figures[measured.session_id]&.then { Keryx::Context.new(used: it, window: nil) }
    end
  end

  def test_a_figure_read_while_another_session_joined_or_the_ceiling_changed_is_dropped
    occupant = impl(director: 'orq.dev')
    meter.figures['session-impl'] = 100_000
    replacement = nil
    bound_while_read(-> { replacement })
    [occupant.with(session_id: 'session-new', joined_at: LATER), occupant.with(ceiling: 500_000)].each do |other|
      store.bind('impl.dev', occupant)
      replacement = other
      round = courier.round

      assert_equal [[], []], [round.context, round.errors]
    end
    assert_empty bodies('impl.dev') + bodies('orq.dev')
  end

  def test_a_figure_read_while_the_session_recorded_its_process_again_is_told
    occupant = impl
    meter.figures['session-impl'] = 100_000
    bound_while_read(-> { occupant.with(pid: 77) })

    assert_equal [['impl.dev@athena', :near]], told.call(courier.round)
  end

  def test_sessions_without_a_ceiling_or_that_ended_are_not_read
    impl(ceiling: nil)
    store.create_address('docs.dev')
    store.bind('docs.dev', build_occupant(session_id: 'session-docs', pid: 999, started: 'started 999', ceiling: 1000))
    meter.figures.merge!('session-impl' => 900_000, 'session-docs' => 900_000)

    assert_empty courier.round.context
    assert_empty meter.reads
  end
end
