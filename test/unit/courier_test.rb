# frozen_string_literal: true

require 'test_helper'

class CourierTest < Minitest::Test
  include TempDir
  include Factory

  LATER = NOW + 3600

  class QuietBell
    def ring(*) = Keryx::Bell::Result.new(status: 'rung', channel: 'test', detail: nil, at: Factory::NOW)
  end

  class Meter
    attr_reader :figures, :reads

    def initialize
      @figures = {}
      @reads = []
    end

    def read(occupant)
      @reads << occupant.session_id
      figures[occupant.session_id]&.then { Keryx::Context.new(used: it, window: nil) }
    end
  end

  def store = @store ||= Keryx::Store.new(tmp('state')).tap { |box| %w[orq rev-1].each { box.create_address(it) } }

  def meter = @meter ||= Meter.new

  def postman
    @postman ||= Keryx::Postman.new(store:, bell: QuietBell.new, forwarder: nil, host: 'athena', clock: -> { LATER },
                                    person: 'person')
  end

  def rosters = @rosters ||= []

  def courier
    @courier ||= Keryx::Courier.new(
      store:, bell: QuietBell.new, postman:, host: 'athena', clock: -> { LATER }, meter:,
      forwarder: Keryx::Forwarder.new(store:, remote: nil, clock: -> { LATER }),
      roster: lambda do
        herdr = FakeHerdr.new
        lookout = Keryx::Lookout.new(herdr:, processes: CLIHelpers::FakeProcesses.new([]))
        Keryx::Roster.new(store:, herdr:, lookout:).tap { rosters << it }
      end
    )
  end

  def overdue_request
    build_message(to: 'rev-1@athena', from: 'orq@athena', kind: 'request', due_at: NOW + 60)
      .tap { store.deliver('rev-1', it) }
  end

  def notices = store.unread('orq').select { it.from == 'keryx@athena' }

  def fail_first_post
    original = postman.method(:post)
    failures = [Errno::ENOSPC.new('mail')]
    postman.define_singleton_method(:post) do |**args|
      raise failures.shift if failures.any?

      original.call(**args)
    end
  end

  def test_a_deadline_notice_that_failed_is_posted_on_the_next_round
    request = overdue_request
    fail_first_post
    first = courier.round

    assert_equal [[], 1], [first.overdue, first.errors.size]
    assert_empty notices
    assert_equal [request], courier.round.overdue
    assert_equal 1, notices.size
    assert_empty courier.round.overdue
  end

  def test_a_notice_posted_twice_is_stored_once
    request = overdue_request
    courier.round
    FileUtils.rm_f(tmp('state', 'addresses', 'orq', 'receipts', "#{request.id}.overdue"))
    courier.round

    assert_equal 1, notices.size
  end

  def test_a_damaged_bell_receipt_does_not_stop_the_round
    store.bind('rev-1', build_occupant)
    message = build_message(to: 'rev-1@athena').tap { store.deliver('rev-1', it) }
    File.write(tmp('state', 'addresses', 'rev-1', 'receipts', "#{message.id}.bell"), '[]')
    round = courier.round

    assert_equal ['rev-1'], round.rung.keys
    assert_match(/#{message.id}\.bell is not a JSON object/, store.problems.first)
  end

  def test_each_round_reads_the_sessions_afresh
    2.times { courier.round }

    assert_equal 2, rosters.uniq.size
  end

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
                  'impl@athena has 126k tokens of context in use and reached its 125k ceiling. It should reach a ' \
                  'stopping point now.'], bodies('orq').sort
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

  def test_sessions_without_a_ceiling_or_that_ended_are_not_read
    impl(ceiling: nil)
    store.create_address('docs')
    store.bind('docs', build_occupant(session_id: 'session-docs', pid: 999, started: 'started 999', ceiling: 1000))
    meter.figures.merge!('session-impl' => 900_000, 'session-docs' => 900_000)

    assert_empty courier.round.context
    assert_empty meter.reads
  end
end
