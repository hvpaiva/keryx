# frozen_string_literal: true

require 'test_helper'

class ProcessesTest < Minitest::Test
  include TempDir

  Killer = Struct.new(:error) do
    def kill(_signal, _pid)
      raise error if error

      1
    end
  end

  def stat(pid, line)
    FileUtils.mkdir_p(tmp('proc', pid.to_s))
    File.write(tmp('proc', pid.to_s, 'stat'), line)
  end

  def linux = Keryx::Processes.new(runner: FakeRunner.new, proc_root: tmp('proc'), host_os: 'linux-gnu')

  def test_a_process_is_alive_while_a_signal_can_reach_it
    assert Keryx::Processes.new(process: Killer.new(nil)).alive?(7)
    refute Keryx::Processes.new(process: Killer.new(Errno::ESRCH)).alive?(7)
    assert Keryx::Processes.new(process: Killer.new(Errno::EPERM)).alive?(7)
  end

  def test_on_linux_the_start_is_the_kernel_tick_count_whatever_the_command_name_holds
    stat(42, "42 (a) (b c) S 1 42 42 0 -1 4194560 100 0 0 0 0 0 0 0 20 0 1 0 30723606 1000 20\n")
    stat(43, "43 (short) S 1 43\n")
    stat(44, "44 no name S 1 42 42 0 -1 4194560 100 0 0 0 0 0 0 0 20 0 1 0 30723606 1000 20\n")

    assert_equal '30723606', linux.started(42)
    assert_nil linux.started(43)
    assert_nil linux.started(44)
    assert_nil linux.started(45)
    assert_nil linux.started('../42')
  end

  def test_elsewhere_the_start_is_read_from_ps_in_the_c_locale_and_utc
    runner = FakeRunner.new(%w[ps -o lstart=] => { out: "Thu Oct 22 16:35:26 2026\n" })

    assert_equal 'Thu Oct 22 16:35:26 2026', Keryx::Processes.new(runner:, host_os: 'darwin24').started(42)
    assert_equal [%w[ps -o lstart= -p 42], { 'LC_ALL' => 'C', 'TZ' => 'UTC0' }], runner.calls.first
    assert_nil Keryx::Processes.new(runner: FakeRunner.new, host_os: 'darwin24').started(42)
    assert_nil Keryx::Processes.new(runner: FakeRunner.new(%w[ps] => { out: "\n" }), host_os: 'darwin24').started(42)
  end

  def test_ancestors_follow_the_parents_up_to_the_first_process
    table = "  1     0\n 10     1\n 20    10\n 30    20\n garbage\n"
    processes = Keryx::Processes.new(runner: FakeRunner.new(%w[ps -A] => { out: table }))

    assert_equal [20, 10, 1], processes.ancestors(30)
    assert_empty Keryx::Processes.new(runner: FakeRunner.new).ancestors(30)
  end
end
