# frozen_string_literal: true

require 'test_helper'

class WaitTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  # A civil clock set by STEP seconds on its first advance, as when someone or NTP sets the system time.
  class SteppedClock < CLIHelpers::Clock
    def initialize(now, step)
      super(now)
      @step = step
    end

    def advance(seconds)
      super(seconds + @step)
      @step = 0
    end
  end

  def setup
    super
    @orq = join_claude('orq.dev', 111)
    @rev = join_claude('rev-1.dev', 222)
  end

  def test_the_timeout_holds_when_the_civil_clock_steps_back
    assert_times_out_after_five_seconds(-3600)
  end

  def test_the_timeout_holds_when_the_civil_clock_steps_forward
    assert_times_out_after_five_seconds(3600)
  end

  def test_the_timeout_holds_when_the_civil_clock_does_not_step
    assert_times_out_after_five_seconds(0)
  end

  private

  def assert_times_out_after_five_seconds(step)
    keryx('ask', 'rev-1.dev', 'Review PR #448', env: @orq)
    id = last_id(@rev)
    @clock = SteppedClock.new(clock.now, step)
    civil = clock.now
    started = monotonic.now
    result = keryx('wait', id, '--timeout', '5s', env: @orq)

    assert_equal 3, result.status
    assert_equal 5, monotonic.now - started
    assert_equal 5 + step, clock.now - civil
  end
end
