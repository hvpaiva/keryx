# frozen_string_literal: true

require 'test_helper'

# A ceiling notice whose recipient on this machine is retired, which takes no mail.
class CourierRetiredTest < Minitest::Test
  include TempDir
  include Factory
  include CourierHelpers

  def test_a_retired_director_here_is_reported_once_and_not_tried_again
    impl(director: 'orq.dev')
    store.retire('orq.dev', by: 'person.local', now: NOW)
    meter.figures['session-impl'] = 100_000
    first = courier.round
    second = courier.round

    assert_equal [['impl.dev@athena', :near]], told.call(first)
    assert_equal ['did not tell orq.dev@athena about the context of impl.dev@athena; ' \
                  'orq.dev@athena is retired; mail to it is refused'], first.errors
    assert_equal [[], []], [second.context, second.errors]
  end

  def test_the_ceiling_after_it_is_reported_once_too
    impl(director: 'orq.dev')
    store.retire('orq.dev', by: 'person.local', now: NOW)
    meter.figures['session-impl'] = 100_000
    courier.round
    meter.figures['session-impl'] = 126_000

    assert_equal 1, courier.round.errors.size
    assert_empty courier.round.errors
  end
end
