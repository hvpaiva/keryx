# frozen_string_literal: true

require 'test_helper'
require_relative 'change_signal_test'

# Each command here makes one kind of change to the store and no other, so the signal moves only because the write
# that made it noted it.
class ChangeSignalSitesTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include ChangeSignalHelpers

  # The person's address is there, so inbox from a plain terminal only makes again the folder it lost.
  def test_a_folder_made_again_for_the_person_moves_the_signal
    keryx('inbox')
    folder = tmp('state', 'addresses', 'person.local', 'tmp')
    Dir.rmdir(folder)
    before = mtime
    result = keryx('inbox')

    assert_equal 0, result.status, result.err
    assert File.directory?(folder), "#{folder} was not made again"
    assert_signaled before
  end

  # A courier that wrote the outcome and stopped before the move left the message in new/, so the next one sends
  # nothing and only moves it.
  def test_a_courier_that_only_moves_a_decided_message_moves_the_signal
    @orq = join_claude('orq.dev', 111)
    remote.down << 'zeus'
    keryx('send', 'port.dev@zeus', 'hello', env: @orq)
    id = File.basename(outbox('new').first, '.json')
    store.outbox.write_outcome('zeus', id, { 'status' => 'forwarded', 'at' => NOW.iso8601 })
    before = mtime
    result = keryx('courier', '--once')

    assert_equal [0, "forwarded #{id} to zeus\n"], [result.status, result.out], result.err
    assert_equal [[], ["#{id}.json"]], [outbox('new'), outbox('cur')]
    assert_signaled before
  end

  # A purge cut short left its mark and only mail, which is a file here, so this one removes that file and no folder.
  def test_a_purge_that_only_removes_a_file_in_place_of_a_folder_moves_the_signal
    retired_and_marked
    %w[tmp receipts read mail].each { FileUtils.rm_r(box(it)) }
    File.write(box('mail'), '')
    before = mtime
    result = keryx('purge', 'rev-1.dev', env: @orq)

    assert_equal 0, result.status, result.err
    assert_match(/\AFinished purging rev-1.dev@athena, .*, removing 1 message, 0 read marks, 0 receipts and 0 files /,
                 result.out)
    assert_equal %w[address.json retired.json], Dir.children(box).sort
    assert_signaled before
  end

  # rm_r empties the folder and then fails to remove it, which ends the purge with an error after a removal made.
  def test_a_purge_that_stops_partway_moves_the_signal_for_what_it_removed
    skip 'root removes entries from a folder it may not write' if Process.euid.zero?
    retired_and_marked
    FileUtils.mkdir_p(box('tmp', 'held'))
    File.write(box('tmp', 'held', 'part'), '')
    File.chmod(0o500, box('tmp'))
    before = mtime
    result = begin
      keryx('purge', 'rev-1.dev', env: @orq)
    ensure
      File.chmod(0o700, box('tmp'))
    end

    assert_equal 1, result.status
    assert_match(/\Aerror: unexpected Errno::EACCES: /, result.err)
    assert_empty Dir.children(box('tmp', 'held'))
    assert_signaled before
  end

  # A courier that posted the reminder and stopped before its mark left the reminder in the mailbox, so the next one
  # posts it again under the same id, which writes nothing, and only marks it.
  def test_a_courier_that_only_marks_a_reminder_moves_the_signal
    join_both
    keryx('ask', 'rev-1.dev', 'Review it', '--within', '1m', env: @orq)
    clock.advance(120)
    keryx('courier', '--once')
    id = store.stored('rev-1.dev').first.message.id
    mark = tmp('state', 'addresses', 'orq.dev', 'receipts', "#{id}.overdue")
    File.delete(mark)
    before = mtime
    result = keryx('courier', '--once')

    assert_equal [0, "told orq.dev@athena that #{id} to rev-1.dev@athena is past its deadline\n"],
                 [result.status, result.out], result.err
    assert_equal 1, store.stored('orq.dev').size
    assert_path_exists mark
    assert_signaled before
  end

  # The courier signals what a round changed before it warns, so a signal that failed is told before the first sleep.
  def test_a_courier_warns_of_a_failed_signal_before_it_first_sleeps
    join_both
    sockets.gone << '/tmp/cc-222.sock'
    keryx('send', 'rev-1.dev', 'hello', env: @orq)
    sockets.gone.clear
    FileUtils.rm_f(signal)
    Dir.mkdir(signal)
    status, warned = courier_until_first_sleep

    assert_equal Keryx::CLI::Dispatcher::SIGINT_STATUS, status
    assert_equal 'rung', store.receipt('rev-1.dev', store.stored('rev-1.dev').first.message.id, 'bell')['status']
    assert_equal 1, warned.lines.count { it.start_with?('warning:') && it.include?(signal) }, warned
  end

  private

  def outbox(state) = Dir.children(tmp('state', 'outbox', 'zeus', state))

  # Retired from orq.dev's session, with the mark of a purge that was cut short before it removed anything.
  def retired_and_marked
    join_both
    alive.delete(222)
    result = keryx('retire', 'rev-1.dev', env: @orq)
    raise "retire failed: #{result.err}" unless result.status.zero?

    mark = store.retired('rev-1.dev').with(purged_at: clock.now, purged_by: 'orq.dev@athena').record
    File.write(box('retired.json'), JSON.generate(mark))
  end

  # The courier as a service from a plain terminal, stopped at its first sleep, with what it had written to err then.
  def courier_until_first_sleep
    err = StringIO.new
    terminal = Keryx::CLI::Terminal.new(out: StringIO.new, err:, env: base_env)
    warned = nil
    sleeper = lambda do |_seconds|
      warned = err.string.dup
      raise Interrupt
    end
    factory = lambda do |_globals|
      Keryx::App.new(env: terminal.env, cwd: '/work', clock:, herdr:, claude_socket: sockets, codex:, remote:, sleeper:,
                     processes:)
    end
    [Keryx.run(%w[courier], terminal:, app_factory: factory), warned]
  end
end
