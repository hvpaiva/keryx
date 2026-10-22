# frozen_string_literal: true

require 'test_helper'

class CourierTest < Minitest::Test
  include TempDir
  include Factory

  LATER = NOW + 3600

  class QuietBell
    def ring(*) = Keryx::Bell::Result.new(status: 'rung', channel: 'test', detail: nil, at: Factory::NOW)
  end

  def store = @store ||= Keryx::Store.new(tmp('state')).tap { |box| %w[orq rev-1].each { box.create_address(it) } }

  def postman
    @postman ||= Keryx::Postman.new(store:, bell: QuietBell.new, forwarder: nil, host: 'athena', clock: -> { LATER },
                                    person: 'person')
  end

  def rosters = @rosters ||= []

  def courier
    @courier ||= Keryx::Courier.new(
      store:, bell: QuietBell.new, postman:, host: 'athena', clock: -> { LATER },
      forwarder: Keryx::Forwarder.new(store:, remote: nil, clock: -> { LATER }),
      roster: -> { Keryx::Roster.new(store:, herdr: FakeHerdr.new).tap { rosters << it } }
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

  def test_each_round_reads_the_sessions_afresh
    2.times { courier.round }

    assert_equal 2, rosters.uniq.size
  end
end
