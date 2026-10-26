# frozen_string_literal: true

require 'test_helper'

# Each stub is a shell script run with / as its folder and a cleared environment, so whatever it records goes to an
# absolute path written into the script. A run that should end at once gets a timeout of 5 s and must end within 1 s,
# so waiting for the deadline shows; a run that should time out gets 1 s and must end within 3 s.
class CheckerTest < Minitest::Test
  include TempDir

  Outcome = Keryx::Checker::Outcome
  PROMPT = 1
  SETTLE = 1
  # What a POSIX shell exports on its own: dash adds PWD, and bash, which is /bin/sh on macOS, SHLVL and _ too.
  SHELL_OWN = %w[PWD SHLVL _].freeze
  FLOOD = <<~'SH'
    head -c 1048576 /dev/zero
    head -c 1048576 /dev/zero | tr '\000' x >&2
    exit 1
  SH

  def record = tmp('record')

  def stub(body, first: '#!/bin/sh')
    File.write(tmp('checker'), "#{first}\n#{body}\n")
    File.chmod(0o755, tmp('checker'))
    tmp('checker')
  end

  def run_stub(body, envelope: "{}\n", timeout: 5, first: '#!/bin/sh')
    Keryx::Checker.new.call(Keryx::CheckConfig::Setup.new(command: stub(body, first:), timeout:), envelope)
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def timed
    start = now
    [yield, now - start]
  end

  # A signal reaches a process at once, but an orphan stays a zombie until init reaps it, and kill finds a zombie.
  def assert_gone(pid)
    deadline = now + SETTLE
    sleep 0.01 while alive?(pid) && now < deadline
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def with_env(values)
    saved = values.keys.to_h { [it, ENV.fetch(it, nil)] }
    values.each { |name, value| ENV[name] = value }
    yield
  ensure
    saved.each { |name, value| ENV[name] = value }
  end

  # Runs a checker that sleeps with a child beside it, raises Interrupt in this thread from another once it has
  # started, and gives the checker's pid and the seconds the run took to end after the Interrupt.
  def interrupted
    main = Thread.current
    raised = nil
    raiser = Thread.new do
      deadline = now + 5
      sleep 0.01 until File.size?(record) || now > deadline
      sleep 0.2
      raised = now
      main.raise(Interrupt)
    end
    assert_raises(Interrupt) { run_stub("echo $$ > #{record}\nsleep 30 &\nexec sleep 30", timeout: 10) && raiser.join }
    [File.read(record).to_i, now - raised]
  ensure
    raiser&.kill&.join
  end

  def test_exit_zero_accepts
    assert_equal Outcome.new(status: 0), run_stub('exit 0')
  end

  def test_exit_one_refuses_with_the_stderr
    assert_equal Outcome.new(status: 1, stderr: 'subject line missing'),
                 run_stub("echo 'subject line missing' >&2\nexit 1")
  end

  def test_exit_two_gives_its_status_and_stderr
    assert_equal Outcome.new(status: 2, stderr: 'cannot reach the policy'),
                 run_stub("echo 'cannot reach the policy' >&2\nexit 2")
  end

  def test_a_checker_killed_by_a_signal_gives_the_signal
    assert_equal Outcome.new(signal: Signal.list.fetch('SEGV')), run_stub("ulimit -c 0\nkill -SEGV $$")
  end

  def test_a_checker_that_cannot_be_run_gives_the_error
    outcome = run_stub('exit 0', first: '#!/nonexistent/keryx/interpreter')

    assert_nil outcome.status
    assert_equal "cannot run #{tmp('checker')}: No such file or directory", outcome.error
  end

  def test_a_checker_past_its_timeout_is_killed_with_its_group_and_reaped
    outcome, elapsed = timed { run_stub("echo $$ > #{record}\nsleep 30 &\nexec sleep 30", timeout: 1) }
    pid = File.read(record).to_i

    assert_equal Outcome.new(timed_out: 1), outcome
    assert_operator elapsed, :<, 3
    assert_gone(-pid)
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  end

  def test_a_checker_that_never_reads_a_large_envelope_is_decided_by_its_exit
    outcome, elapsed = timed { run_stub('exit 0', envelope: "#{'x' * (256 * 1024)}\n") }

    assert_equal Outcome.new(status: 0), outcome
    assert_operator elapsed, :<, PROMPT
  end

  def test_a_flood_on_both_outputs_is_drained_and_only_four_kilobytes_of_stderr_kept
    outcome, elapsed = timed { run_stub(FLOOD) }

    assert_equal Outcome.new(status: 1, stderr: "#{'x' * 4096}\n(cut at 4096 bytes)"), outcome
    assert_operator elapsed, :<, PROMPT
  end

  def test_the_checker_reads_the_envelope_byte_for_byte
    envelope = "{\"body\":\"caf\u00e9 #{'y' * 100_000}\"}\n"

    assert_equal Outcome.new(status: 0), run_stub("exec cat > #{record}", envelope:)
    assert_equal envelope.b, File.binread(record)
  end

  def test_the_checker_gets_four_variables_and_the_home_of_its_user
    with_env('KERYX_CHECK_SENTINEL' => 'leaked', 'HOME' => tmp) do
      assert_equal Outcome.new(status: 0), run_stub("exec /usr/bin/env > #{record}")
    end
    env = File.read(record).lines(chomp: true).to_h { it.split('=', 2) }

    # Names before values, so a leak shows which variables passed and none of what they hold.
    refute_includes env.keys, 'KERYX_CHECK_SENTINEL'
    assert_equal %w[HOME KERYX_CHECK LANG PATH], (env.keys - SHELL_OWN).sort
    assert_equal({ 'PATH' => '/usr/bin:/bin', 'HOME' => Etc.getpwuid(Process.uid).dir, 'LANG' => 'C.UTF-8',
                   'KERYX_CHECK' => '1' }, env.slice('PATH', 'HOME', 'LANG', 'KERYX_CHECK'))
    assert_equal '/', env.fetch('PWD', '/')
  end

  def test_the_checker_runs_in_the_root_folder
    assert_equal Outcome.new(status: 0), run_stub("pwd -P > #{record}")
    assert_equal "/\n", File.read(record)
  end

  def test_the_checker_gets_its_path_alone_as_its_arguments
    assert_equal Outcome.new(status: 0), run_stub("echo \"$0 $#\" > #{record}")
    assert_equal "#{tmp('checker')} 0\n", File.read(record)
  end

  def test_a_child_the_checker_leaves_behind_neither_delays_the_answer_nor_outlives_it
    outcome, elapsed = timed { run_stub("sleep 30 &\necho $$ $! > #{record}\nexit 0") }
    group, child = File.read(record).split.map(&:to_i)

    assert_equal Outcome.new(status: 0), outcome
    assert_operator elapsed, :<, PROMPT
    assert_gone(child)
    assert_gone(-group)
  end

  def test_an_interrupt_during_the_check_propagates_and_leaves_no_process_or_zombie
    pid, elapsed = interrupted

    assert_operator elapsed, :<, PROMPT
    assert_gone(-pid)
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  end

  # A first run opens whatever Ruby opens once for threads and children, and GC closes what earlier tests dropped
  # unclosed, so the count after can only grow by what the interrupted run left open.
  def test_an_interrupt_during_the_check_leaves_no_descriptor_open
    skip 'no /proc/self/fd to count descriptors in' unless File.directory?('/proc/self/fd')
    run_stub('exit 0')
    GC.start
    before = Dir.children('/proc/self/fd').size
    interrupted

    assert_operator Dir.children('/proc/self/fd').size, :<=, before
  end
end

class CheckTest < Minitest::Test
  include Factory

  COMMAND = '/usr/local/libexec/nomos-check'
  SETUP = Keryx::CheckConfig::Setup.new(command: COMMAND, timeout: 7)
  HEAD = '{"check":1,"event":"send","host":"athena","command":"send --re","message":{"keryx":2,'
  Outcome = Keryx::Checker::Outcome

  # A CheckConfig whose setup gives RESULT, or raises it when it is an error.
  Config = Data.define(:result) do
    def setup = result.is_a?(Exception) ? raise(result) : result
  end

  # A Checker that answers OUTCOME and records what it was called with.
  class FakeChecker
    attr_reader :calls

    def initialize(outcome)
      @outcome = outcome
      @calls = []
    end

    def call(setup, envelope)
      @calls << [setup, envelope]
      @outcome
    end
  end

  def check(outcome = Outcome.new(status: 0), host: 'athena', config: Config.new(SETUP))
    @checker = FakeChecker.new(outcome)
    Keryx::Check.new(host:, config:, checker: @checker)
  end

  def mail = @mail ||= build_message(to: 'port.dev@zeus', from: 'orq.dev@athena', body: "one\ntwo")

  def refusal(outcome, event: 'send', host: 'athena')
    check(outcome, host:).refusal(mail, event:, command: event == 'send' ? 'send' : nil)
  end

  def test_exit_zero_lets_the_message_through
    assert_nil refusal(Outcome.new(status: 0))
    assert_equal 1, @checker.calls.size
  end

  def test_exit_one_on_send_refuses_with_the_stderr_as_given
    assert_equal "the check refused the message:\nsubject line missing\nbody empty",
                 refusal(Outcome.new(status: 1, stderr: "subject line missing\nbody empty"))
  end

  def test_exit_one_without_stderr_refuses_without_a_reason
    assert_equal 'the check refused the message and gave no reason', refusal(Outcome.new(status: 1))
  end

  def test_exit_two_fails_with_the_status_and_the_stderr_when_there_is_any
    assert_equal "the check failed: #{COMMAND} exited with status 2: policy unreachable",
                 refusal(Outcome.new(status: 2, stderr: 'policy unreachable'))
    assert_equal "the check failed: #{COMMAND} exited with status 3", refusal(Outcome.new(status: 3))
  end

  def test_a_timeout_a_signal_and_a_failed_start_fail
    assert_equal "the check failed: #{COMMAND} did not finish within 5s", refusal(Outcome.new(timed_out: 5))
    assert_equal "the check failed: #{COMMAND} was killed by SIGSEGV",
                 refusal(Outcome.new(signal: Signal.list.fetch('SEGV')))
    assert_equal "the check failed: cannot run #{COMMAND}: Permission denied",
                 refusal(Outcome.new(error: "cannot run #{COMMAND}: Permission denied"))
  end

  def test_a_broken_config_fails_with_its_text_and_runs_nothing
    config = Config.new(Keryx::Check::Broken.new('/etc/keryx/check names no command'))

    assert_equal 'the check failed: /etc/keryx/check names no command',
                 check(config:).refusal(mail, event: 'send', command: 'send')
    assert_empty @checker.calls
  end

  def test_on_receive_the_reason_names_the_machine_on_one_line
    assert_equal 'the check on zeus refused the message: subject line missing body empty',
                 refusal(Outcome.new(status: 1, stderr: "subject line missing\n\n  body empty"), event: 'receive',
                                                                                                 host: 'zeus')
    assert_equal "the check on zeus failed: #{COMMAND} exited with status 2: policy down since noon",
                 refusal(Outcome.new(status: 2, stderr: "policy down\nsince noon"), event: 'receive', host: 'zeus')
    assert_equal 'the check on zeus refused the message and gave no reason',
                 refusal(Outcome.new(status: 1), event: 'receive', host: 'zeus')
  end

  def test_keryx_notices_and_a_persons_mail_are_exempt_and_an_agents_is_not
    assert check.exempt?(build_message(to: 'orq.dev@athena', from: 'keryx.system@zeus'))
    assert check.exempt?(build_message(to: 'orq.dev@athena', from: 'person.local@athena'))
    refute check.exempt?(build_message(to: 'port.dev@zeus', from: 'orq.dev@athena'))
  end

  def test_an_exempt_message_runs_no_checker
    notice = build_message(to: 'orq.dev@athena', from: 'keryx.system@zeus')

    assert_nil check(Outcome.new(status: 1, stderr: 'no')).refusal(notice, event: 'send', command: 'send')
    assert_empty @checker.calls
  end

  def test_the_timeout_for_a_message
    assert_nil check.timeout_for(build_message(to: 'orq.dev@athena', from: 'keryx.system@zeus'))
    assert_nil check(config: Config.new(nil)).timeout_for(mail)
    assert_equal 0, check(config: Config.new(Keryx::Check::Broken.new('broken'))).timeout_for(mail)
    assert_equal 7, check.timeout_for(mail)
  end

  def test_the_envelope_is_one_json_line_of_the_event_the_machine_the_command_and_the_message
    check.refusal(mail, event: 'send', command: 'send --re')
    setup, envelope = @checker.calls.fetch(0)

    assert_equal SETUP, setup
    assert_equal HEAD, envelope[0, HEAD.size]
    assert_equal ["}}\n", 1], [envelope[-3..], envelope.count("\n")]
    assert_equal({ 'check' => 1, 'event' => 'send', 'host' => 'athena', 'command' => 'send --re',
                   'message' => JSON.parse(mail.to_json) }, JSON.parse(envelope))
  end

  def test_the_envelope_on_receive_has_no_command
    check.refusal(mail, event: 'receive', command: nil)

    assert_equal({ 'check' => 1, 'event' => 'receive', 'host' => 'athena', 'command' => nil,
                   'message' => JSON.parse(mail.to_json) }, JSON.parse(@checker.calls.fetch(0).last))
  end
end
