# frozen_string_literal: true

require 'test_helper'

# The mtime of Changes::FILE moves forward once for the changes noted, whatever the clock does.
class ChangesTest < Minitest::Test
  include TempDir
  include Factory

  def setup
    super
    FileUtils.mkdir_p(tmp('state'))
    @now = NOW
  end

  def changes = @changes ||= Keryx::Changes.new(tmp('state'), clock: -> { @now })

  def signal = changes.tap(&:note).signal

  def mtime = File.lstat(tmp('state', 'changed')).mtime

  def test_a_signal_makes_the_file_private_and_stamps_the_clock
    signal

    stat = File.lstat(tmp('state', 'changed'))

    assert_predicate stat, :file?
    assert_equal 0o600, stat.mode & 0o777
    @now = mtime + 60
    signal

    assert_equal @now, mtime
  end

  def test_nothing_noted_signals_nothing
    changes.signal

    refute_path_exists tmp('state', 'changed')
  end

  def test_two_signals_in_one_tick_of_the_clock_differ_by_a_millisecond
    @now = Time.now.utc + 3600
    signal
    first = mtime
    signal

    assert_equal first + Keryx::Changes::STEP, mtime
  end

  def test_a_clock_that_stepped_back_still_moves_the_mtime_forward
    @now = Time.now.utc + 3600
    signal
    first = mtime
    @now -= 3600
    signal

    assert_equal first + Keryx::Changes::STEP, mtime
  end

  def test_a_signal_clears_the_note
    signal

    refute_predicate changes, :pending?
    first = mtime
    changes.signal

    assert_equal first, mtime
  end

  def test_a_filesystem_that_keeps_whole_seconds_moves_it_by_a_second
    @now = Time.now.utc.floor + 3600
    changes.define_singleton_method(:stamp) { |time| File.lutime(time.floor, time.floor, path) }
    signal
    signal

    assert_equal @now + 1, mtime
  end

  def test_a_filesystem_that_keeps_no_new_time_fails_and_keeps_the_note
    changes.define_singleton_method(:stamp) { |_time| nil }
    error = assert_raises(Keryx::Error) { signal }

    assert_match(/changed kept its mtime/, error.message)
    assert_predicate changes, :pending?
  end

  def test_a_link_in_place_of_the_file_is_refused_and_its_target_keeps_its_time
    File.write(tmp('target'), '')
    File.utime(NOW, NOW, tmp('target'))
    File.symlink(tmp('target'), tmp('state', 'changed'))

    assert_raises(Keryx::Links::Linked) { signal }
    assert_equal NOW, File.lstat(tmp('target')).mtime
    assert_predicate changes, :pending?
  end

  def test_a_folder_in_place_of_the_file_fails_and_a_later_signal_succeeds
    Dir.mkdir(tmp('state', 'changed'))

    assert_raises(SystemCallError) { signal }
    Dir.rmdir(tmp('state', 'changed'))
    changes.signal

    assert_predicate File.lstat(tmp('state', 'changed')), :file?
  end

  def test_a_named_pipe_in_place_of_the_file_is_not_a_regular_file
    File.mkfifo(tmp('state', 'changed'))

    error = assert_raises(Keryx::Error) { signal }
    assert_match(/is not a regular file/, error.message)
  end
end

# The store notes only the writes that changed it, and reports a signal that failed instead of raising it.
class StoreChangesTest < Minitest::Test
  include TempDir
  include Factory

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def test_a_removal_that_finds_nothing_and_a_folder_already_there_signal_nothing
    Keryx::Store.new(tmp('state')).tap { it.create_address('rev-1.dev') }.signal_changes
    File.delete(tmp('state', 'changed'))
    store.create_address('rev-1.dev')
    store.unbind('rev-1.dev')
    store.unmark('rev-1.dev', 'missing', 'bell')
    store.signal_changes

    refute_path_exists tmp('state', 'changed')
  end

  def test_a_delivery_signals_once_made
    store.create_address('rev-1.dev')
    store.deliver('rev-1.dev', build_message(to: 'rev-1.dev@athena'))
    store.signal_changes

    assert_predicate File.lstat(tmp('state', 'changed')), :file?
    assert_empty store.problems
  end

  def test_a_signal_that_fails_is_a_problem_and_not_an_error
    store.create_address('rev-1.dev')
    Dir.mkdir(tmp('state', 'changed'))
    store.signal_changes

    assert_equal 1, store.problems.size
    watched = Regexp.escape(tmp('state', 'changed'))

    assert_match(/the store changed, but its readers that watch #{watched} miss it/, store.problems.first)
  end
end
