# frozen_string_literal: true

require 'test_helper'
require 'rbconfig'

class RunnerTest < Minitest::Test
  RUBY = RbConfig.ruby

  def test_it_captures_output_and_the_status
    result = Keryx::Runner.new.call([RUBY, '-e', '$stdout.print "out"; warn "err"; exit 3'])

    assert_equal 'out', result.out
    assert_equal "err\n", result.err
    refute result.success
  end

  def test_it_passes_the_environment
    result = Keryx::Runner.new.call([RUBY, '-e', 'print ENV["KERYX_PROBE"]'], env: { 'KERYX_PROBE' => 'yes' })

    assert_equal 'yes', result.out
    assert result.success
  end

  def test_it_feeds_standard_input
    result = Keryx::Runner.new.call([RUBY, '-e', 'print $stdin.read.upcase'], input: "one\ntwo\n")

    assert_equal "ONE\nTWO\n", result.out
  end

  def test_it_stops_a_command_past_the_deadline
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Keryx::Runner.new(timeout: 0.3).call([RUBY, '-e', 'sleep 30'])

    refute result.success
    assert_match(/did not finish within 0.3s/, result.err)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  def test_the_deadline_covers_a_child_that_keeps_the_output_open
    marker = File.join(Dir.tmpdir, "keryx-runner-#{Process.pid}-#{rand(1_000_000)}")
    script = "fork { sleep 2; File.write(#{marker.inspect}, 'survived') }; exit!(0)"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Keryx::Runner.new(timeout: 0.3).call([RUBY, '-e', script])
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    sleep 2.5

    assert_equal [false, true], [result.success, elapsed < 1.9]
    refute_path_exists marker
  ensure
    FileUtils.rm_f(marker)
  end

  def test_a_started_command_can_be_polled_and_stopped
    job = Keryx::Runner.new.start([RUBY, '-e', 'sleep 30'])
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    refute_predicate job, :done?
    job.stop

    assert job.done?(within: 5)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  end

  def test_a_started_command_gives_its_result_once_it_ends
    job = Keryx::Runner.new.start([RUBY, '-e', 'print $stdin.read.upcase'], input: 'done')

    assert job.done?(within: 10)
    assert_equal Keryx::Runner::Result.new(out: 'DONE', err: '', success: true), job.result
  end

  def test_a_program_that_cannot_start_is_a_finished_job
    job = Keryx::Runner.new.start(['keryx-no-such-program'])

    assert_predicate job, :done?
    assert_nil job.stop
    assert_match(/keryx-no-such-program/, job.result.err)
  end

  def test_a_missing_program_is_a_failed_result
    result = Keryx::Runner.new.call(['keryx-no-such-program'])

    refute result.success
    assert_match(/keryx-no-such-program/, result.err)
  end
end
