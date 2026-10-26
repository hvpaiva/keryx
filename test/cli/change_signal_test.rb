# frozen_string_literal: true

require 'test_helper'

# The signal file keryx touches after each change to the store, by its mtime alone.
module ChangeSignalHelpers
  private

  def signal = tmp('state', 'changed')

  def mtime(path = signal)
    File.lstat(path).mtime
  rescue Errno::ENOENT
    nil
  end

  def box(*parts) = tmp('state', 'addresses', 'rev-1.dev', *parts)

  def join_both
    @orq = join_claude('orq.dev', 111)
    @rev = join_claude('rev-1.dev', 222)
  end

  def assert_later(before, after, path = signal)
    refute_nil after, "#{path} was not written"
    assert_operator after, :>, before, "#{path} kept its mtime" if before
  end

  def assert_signaled(before, path = signal) = assert_later(before, mtime(path), path)

  def assert_unsignaled(before, path = signal)
    return refute_path_exists(path) unless before

    assert_equal before, mtime(path)
  end
end

class ChangeSignalTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include ChangeSignalHelpers

  def test_send_signals_the_mail_it_delivers
    join_both
    before = mtime
    result = keryx('send', 'rev-1.dev', 'hello', env: @orq)

    assert_equal 0, result.status, result.err
    assert_equal ['hello'], store.unread('rev-1.dev').map(&:body)
    assert_signaled before
  end

  def test_read_signals_the_read_mark
    join_both
    keryx('send', 'rev-1.dev', 'hello', env: @orq)
    id = last_id(@rev)
    before = mtime
    result = keryx('read', id, env: @rev)

    assert_equal 0, result.status, result.err
    assert_equal [:read], store.stored('rev-1.dev').map(&:state)
    assert_signaled before
  end

  def test_a_bell_that_fails_signals_its_receipt
    join_both
    sockets.gone << '/tmp/cc-222.sock'
    before = mtime
    result = keryx('send', 'rev-1.dev', 'hello', env: @orq)

    assert_equal 0, result.status, result.err
    assert_equal 'failed', bell_status
    assert_signaled before
  end

  def test_ring_signals_the_receipt_it_writes
    join_both
    sockets.gone << '/tmp/cc-222.sock'
    keryx('send', 'rev-1.dev', 'hello', env: @orq)
    sockets.gone.clear
    before = mtime
    result = keryx('ring', 'rev-1.dev')

    assert_equal 0, result.status, result.err
    assert_equal 'rung', bell_status
    assert_signaled before
  end

  def test_a_send_to_a_machine_that_is_down_signals_the_outbox
    @orq = join_claude('orq.dev', 111)
    remote.down << 'zeus'
    before = mtime
    result = keryx('send', 'port.dev@zeus', 'hello', env: @orq)

    assert_equal 0, result.status, result.err
    assert_equal 1, outbox('new').size
    assert_signaled before
  end

  def test_the_courier_signals_what_it_forwards
    queued_for_zeus
    remote.down.clear
    before = mtime
    result = keryx('courier', '--once')

    assert_equal 0, result.status, result.err
    assert_equal [0, 1], [outbox('new').size, outbox('cur').size]
    assert_signaled before
  end

  def test_the_courier_signals_what_the_other_machine_refuses
    queued_for_zeus
    @remote = FakeRemote.new do |_host, input|
      input.lines.map { "#{JSON.generate('id' => JSON.parse(it)['id'], 'status' => 'refused', 'detail' => 'no')}\n" }
           .join
    end
    before = mtime
    result = keryx('courier', '--once')

    assert_equal 0, result.status, result.err
    assert_equal [0, 1], [outbox('new').size, outbox('refused').size]
    assert_signaled before
  end

  def test_mail_from_another_machine_signals_the_store_that_receives_it
    on_zeus
    zeus = tmp('zeus', 'changed')
    before = [mtime, mtime(zeus)]
    line = "#{build_message(to: 'port.dev@zeus', from: 'orq.dev@athena').to_json}\n"
    result = keryx('__receive', env: machine('zeus'), input: line)

    assert_equal [0, 'delivered'], [result.status, JSON.parse(result.out)['status']], result.err
    assert_equal ['hello'], Keryx::Store.new(tmp('zeus')).unread('port.dev').map(&:body)
    assert_signaled before.last, zeus
    assert_unsignaled before.first
  end

  def test_read_only_commands_leave_the_signal_as_it_was
    busy_store
    # Made here when missing, so that the test also holds for a keryx that writes no signal.
    FileUtils.touch(signal) unless File.exist?(signal)
    before = mtime

    assert_equal [0] * 5, reads.map(&:status)
    assert_unsignaled before
  end

  def test_read_only_commands_create_no_signal_where_none_is
    busy_store
    FileUtils.rm_f(signal)

    assert_equal [0] * 5, reads.map(&:status)
    refute_path_exists signal
  end

  # inbox is left out: from a plain terminal on a fresh store it creates the person's address.
  def test_read_only_commands_create_no_signal_on_a_fresh_store
    runs = [keryx('who'), keryx('status'), keryx('history')]

    assert_equal [0, 0, 0], runs.map(&:status)
    refute_path_exists signal
  end

  def test_the_signal_is_created_as_a_regular_file_only_its_owner_reads
    alive << 222
    result = keryx('join', 'rev-1.dev', env: claude(222))

    assert_equal 0, result.status, result.err
    assert store.occupant('rev-1.dev')
    assert_path_exists signal
    assert_equal([true, 0o600], File.lstat(signal).then { [it.file?, it.mode & 0o777] })
  end

  def test_a_link_at_the_signal_is_not_followed_and_the_change_stands
    join_both
    File.write(tmp('outside'), '')
    File.utime(NOW, NOW, tmp('outside'))
    FileUtils.rm_f(signal)
    File.symlink(tmp('outside'), signal)
    result = keryx('send', 'rev-1.dev', 'hello', env: @orq)

    assert_equal 0, result.status
    assert_equal ['hello'], store.unread('rev-1.dev').map(&:body)
    assert_warned result
    assert_equal NOW, File.lstat(tmp('outside')).mtime
  end

  def test_a_folder_at_the_signal_is_warned_about_and_the_change_stands
    join_both
    FileUtils.rm_f(signal)
    Dir.mkdir(signal)
    result = keryx('send', 'rev-1.dev', 'hello', env: @orq)

    assert_equal 0, result.status
    assert_equal ['hello'], store.unread('rev-1.dev').map(&:body)
    assert_warned result
  end

  private

  def outbox(state) = Dir.children(tmp('state', 'outbox', 'zeus', state))

  def on_zeus
    @orq = join_claude('orq.dev', 111)
    alive << 333
    keryx('join', 'port.dev', env: machine('zeus').merge(claude(333)))
  end

  def queued_for_zeus
    on_zeus
    remote.down << 'zeus'
    keryx('send', 'port.dev@zeus', 'hello', env: @orq)
  end

  # The person's address exists before the reads, so inbox from the plain terminal only reads it.
  def busy_store
    join_both
    keryx('ask', 'rev-1.dev', 'Review it', env: @orq)
    keryx('send', 'rev-1.dev', 'From a terminal')
  end

  def reads = [keryx('who'), keryx('inbox', env: @rev), keryx('inbox'), keryx('status'), keryx('history', env: @rev)]

  def bell_status
    id = store.stored('rev-1.dev').first.message.id
    store.receipt('rev-1.dev', id, 'bell')&.fetch('status')
  end

  def assert_warned(result)
    warnings = result.err.lines.select { it.start_with?('warning:') && it.include?(signal) }

    assert_equal 1, warnings.size, "no single warning names #{signal}: #{result.err.inspect}"
  end
end

class ChangeSignalSessionTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers
  include ChangeSignalHelpers

  # The clock the sleeper advances, which calls back each time a command sleeps.
  class Sleeps < CLIHelpers::Clock
    def initialize(now, &on_sleep)
      super(now)
      @on_sleep = on_sleep
    end

    def advance(seconds)
      @on_sleep.call
      super
    end
  end

  def test_join_signals_the_occupant_it_records
    keryx('leave', env: join_claude('rev-1.dev', 222))
    alive << 333
    before = mtime
    result = keryx('join', 'rev-1.dev', env: claude(333))

    assert_equal 0, result.status, result.err
    assert_equal 333, store.occupant('rev-1.dev').pid
    assert_signaled before
  end

  def test_leave_signals_the_occupant_it_removes
    rev = join_claude('rev-1.dev', 222)
    before = mtime
    result = keryx('leave', env: rev)

    assert_equal 0, result.status, result.err
    assert_nil store.occupant('rev-1.dev')
    assert_signaled before
  end

  def test_join_force_signals_the_occupant_and_the_displaced_session
    join_claude('rev-1.dev', 222)
    displaced = store.occupant('rev-1.dev').session
    alive << 333
    before = mtime
    result = keryx('join', 'rev-1.dev', '--force', env: claude(333))

    assert_equal 0, result.status, result.err
    assert_equal [333, [displaced]], [store.occupant('rev-1.dev').pid, store.outgoing('rev-1.dev')]
    assert_signaled before
  end

  def test_join_with_a_new_role_signals_the_address_record
    rev = join_claude('rev-1.dev', 222)
    before = mtime
    result = keryx('join', 'rev-1.dev', '--role', 'reviewer', env: rev)

    assert_equal 0, result.status, result.err
    assert_equal 'reviewer', store.address('rev-1.dev').role
    assert_signaled before
  end

  def test_expect_signals_the_record_it_writes
    workspace(%w[w1:t1 main] => { 'w1:p1' => AREA, 'w1:p3' => AREA })
    director = join_claude('orq.dev', 111).merge(CALLER)
    store.create_address('rev-1.dev')
    before = mtime
    result = keryx('expect', 'rev-1.dev', '--harness', 'claude', '--pane', 'w1:p3', env: director)

    assert_equal 0, result.status, result.err
    assert_path_exists box('spawned.json')
    assert_signaled before
  end

  # The session joins at spawn's first sleep, so what the signal says then is what spawn wrote before it slept: the
  # address exists already, and spawn takes no request, so that is its record alone.
  def test_spawn_signals_its_record_before_it_sleeps
    director = join_claude('orq.dev', 111)
    store.create_address('rev-1.dev')
    slept = []
    @monotonic = Sleeps.new(0) do
      slept << [mtime, File.exist?(box('spawned.json'))]
      keryx('join', 'rev-1.dev', env: claude(500).merge(in_pane(SOCKET, 'w1:p2')).tap { alive << 500 }) if slept.one?
    end
    herdr.on_start = ->(socket, pane, _name, kind) { herdr.put(socket, pane, agent(pane, kind, 'working')) }
    before = mtime
    result = spawn('rev-1.dev', '--harness', 'claude', env: director)

    assert_equal 0, result.status, result.err
    assert slept.first&.last, 'spawn slept before it recorded the session it expects'
    assert_later before, slept.first.first
  end

  def test_retire_signals_the_retirement_record
    @orq = join_claude('orq.dev', 111)
    keryx('leave', env: join_claude('rev-1.dev', 222))
    before = mtime
    result = keryx('retire', 'rev-1.dev', env: @orq)

    assert_equal 0, result.status, result.err
    assert store.retired?('rev-1.dev')
    assert_signaled before
  end

  def test_join_revive_signals_the_retirement_record_it_removes
    keryx('leave', env: join_claude('rev-1.dev', 222))
    keryx('retire', 'rev-1.dev')
    alive << 333
    before = mtime
    result = keryx('join', 'rev-1.dev', '--revive', env: claude(333))

    assert_equal 0, result.status, result.err
    refute store.retired?('rev-1.dev')
    assert_signaled before
  end

  def test_purge_signals_its_mark_in_the_retirement_record
    retired_with_mail(1)
    before = mtime
    result = keryx('purge', 'rev-1.dev', env: @orq)

    assert_equal 0, result.status, result.err
    assert_predicate store.retired('rev-1.dev'), :purged?
    assert_signaled before
  end

  # A purge cut short left its mark, so this one only removes; it touches the signal once however many files go.
  def test_a_purge_that_removes_many_files_moves_the_signal_by_one_millisecond
    retired_with_mail(5)
    mark = store.retired('rev-1.dev').with(purged_at: clock.now, purged_by: 'orq.dev@athena').record
    File.write(box('retired.json'), JSON.generate(mark))
    before = mtime
    result = keryx('purge', 'rev-1.dev', env: @orq)

    assert_equal 0, result.status, result.err
    assert_equal %w[address.json retired.json], Dir.children(box).sort
    assert_touched_once before
  end

  private

  # Retired from orq.dev's session, since a retire from a plain terminal also creates the person's address.
  def retired_with_mail(count)
    join_both
    count.times { keryx('send', 'rev-1.dev', "note #{it}", env: @orq) }
    alive.delete(222)
    result = keryx('retire', 'rev-1.dev', env: @orq)
    raise "retire failed: #{result.err}" unless result.status.zero?
  end

  def assert_touched_once(before)
    after = mtime

    refute_nil after, "#{signal} was not written"
    assert_equal Rational(1, 1000), after.to_r - before.to_r, 'one command moves the signal 1 ms past where it was'
  end
end
