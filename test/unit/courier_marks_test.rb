# frozen_string_literal: true

require 'test_helper'

# A ceiling notice is told once for each join, and two joins are two whatever the clock says.
class CourierMarksTest < Minitest::Test
  include TempDir
  include Factory
  include CourierHelpers

  def test_a_join_at_the_instant_of_the_one_before_it_is_told_too
    impl(director: 'orq.dev', session: 'abc123')
    meter.figures['session-impl'] = 100_000
    courier.round
    store.bind('impl.dev', build_occupant(session_id: 'session-next', ceiling: 125_000, director: 'orq.dev',
                                          session: 'def456'))
    meter.figures['session-next'] = 100_000

    assert_equal [['impl.dev@athena', :near], ['orq.dev@athena', :near]], told.call(courier.round)
    assert_empty courier.round.context
  end
end
