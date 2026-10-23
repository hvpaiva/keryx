# frozen_string_literal: true

require 'test_helper'

class ProcessesTest < Minitest::Test
  Killer = Struct.new(:error) do
    def kill(_signal, _pid)
      raise error if error

      1
    end
  end

  def test_a_process_is_alive_while_a_signal_can_reach_it
    assert Keryx::Processes.new(process: Killer.new(nil)).alive?(7)
    refute Keryx::Processes.new(process: Killer.new(Errno::ESRCH)).alive?(7)
    assert Keryx::Processes.new(process: Killer.new(Errno::EPERM)).alive?(7)
  end

  def test_the_start_time_is_read_in_the_c_locale_as_ps_prints_it
    runner = FakeRunner.new(%w[ps -o lstart=] => { out: "Thu Oct 22 16:35:26 2026\n" })

    assert_equal 'Thu Oct 22 16:35:26 2026', Keryx::Processes.new(runner:).started(42)
    assert_equal [%w[ps -o lstart= -p 42], { 'LC_ALL' => 'C' }], runner.calls.first
    assert_nil Keryx::Processes.new(runner: FakeRunner.new).started(42)
    assert_nil Keryx::Processes.new(runner: FakeRunner.new(%w[ps] => { out: "\n" })).started(42)
  end

  def test_ancestors_follow_the_parents_up_to_the_first_process
    table = "  1     0\n 10     1\n 20    10\n 30    20\n garbage\n"
    processes = Keryx::Processes.new(runner: FakeRunner.new(%w[ps -A] => { out: table }))

    assert_equal [20, 10, 1], processes.ancestors(30)
    assert_empty Keryx::Processes.new(runner: FakeRunner.new).ancestors(30)
  end
end
