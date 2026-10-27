# frozen_string_literal: true

require 'test_helper'

# The outbox's locks are waited for 15 seconds at most, as the occupants lock is, so a command stopped while it held
# one, or any other process that keeps the file, holds back no reply and no courier round for good.
class OutboxLockTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  BUSY = '%s stayed locked by another keryx command for 15s; try again, or end that command if it is stuck'

  def teardown
    @threads&.each { it.join(ProcessRaces::SECONDS) }
    super
  end

  def test_a_reply_to_another_machine_gives_up_while_another_command_keeps_the_thread_lock
    orq = join_claude('orq.dev', 111)
    request = build_message(from: 'port.dev@zeus', to: 'orq.dev@athena', kind: 'request')
    store.deliver('orq.dev', request)
    lock = outbox('thread.lock')
    result = holding(lock) { in_time { keryx('reply', request.id, 'Done', env: orq) } }

    assert_equal [1, "error: #{format(BUSY, lock)}\n"], [result.status, result.err]
    assert_in_delta 15, clock.now - NOW, 0.1
    assert_equal ['thread.lock'], outbox_files
    assert_empty remote.sent

    remote.down << 'zeus'

    assert_equal 0, keryx('reply', request.id, 'Done', env: orq).status
    assert_equal([[request.thread, request.id]], store.outbox.queued('zeus').map { [it.thread, it.in_reply_to] })
  end

  private

  def outbox(*parts) = tmp('state', 'outbox', 'zeus', *parts)

  def outbox_files
    Dir.glob('**/*', base: outbox).select { File.file?(outbox(it)) }.sort
  end

  def holding(path)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.open(path, File::RDWR | File::CREAT) do |file|
      file.flock(File::LOCK_EX)
      yield
    end
  end

  # A command that waited for the lock without a deadline would never return while the test holds it.
  def in_time(&)
    thread = Thread.new(&)
    (@threads ||= []) << thread
    flunk('the command still waits for the outbox lock') unless thread.join(ProcessRaces::SECONDS)
    thread.value
  end
end
