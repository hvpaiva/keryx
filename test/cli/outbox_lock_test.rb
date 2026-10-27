# frozen_string_literal: true

require 'test_helper'

# The outbox's locks are waited for 15 seconds at most, as the occupants lock is, so a command stopped while it held
# one, or any other process that keeps the file, holds back no reply and no courier round for good.
class OutboxLockTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  BUSY = '%s stayed locked by another keryx command for 15s; try again, or end that command if it is stuck'
  UNDECIDED = '{"status":"maybe"}'

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

  def test_the_courier_leaves_a_message_waiting_while_another_command_keeps_the_outcomes_lock
    id, = undecided_outcome
    lock = outbox('outcomes.lock')
    began = clock.now
    round = holding(lock) { in_time { keryx('courier', '--once') } }

    assert_equal 0, round.status
    assert_includes round.out, "1 message(s) wait for zeus: #{format(BUSY, lock)}"
    assert_in_delta 15, clock.now - began, 0.1
    assert_equal UNDECIDED, File.read(outbox('receipts', "#{id}.outcome"))
    assert_equal [id], store.outbox.queued('zeus').map(&:id)
  end

  def test_the_next_round_records_the_outcome_once_the_outcomes_lock_is_free
    id, port = undecided_outcome
    holding(outbox('outcomes.lock')) { in_time { keryx('courier', '--once') } }
    after = keryx('courier', '--once')

    assert_includes after.out, "forwarded #{id} to zeus"
    assert_equal 'forwarded', store.outbox.outcome('zeus', id)['status']
    assert_equal [['zeus', [id]], ['zeus', [id]]], remote.sent
    assert_equal([id], JSON.parse(keryx('inbox', '--all', '-o', 'json', env: port).out).map { it['id'] })
  end

  def test_an_old_message_stays_in_new_while_another_command_keeps_the_outcomes_lock
    id = Keryx::Ulid.generate(NOW)
    message = outbox('new', "#{id}.json")
    %w[tmp receipts new cur refused].each { FileUtils.mkdir_p(outbox(it), mode: 0o700) }
    File.write(message, JSON.generate(old_message(id)))
    File.write(outbox('receipts', "#{id}.outcome"), UNDECIDED)
    lock = outbox('outcomes.lock')
    round = holding(lock) { in_time { keryx('courier', '--once') } }

    assert_equal 0, round.status
    assert_includes round.err, "warning: did not move #{message} to refused/: #{format(BUSY, lock)}"
    assert_path_exists message

    after = keryx('courier', '--once')

    assert_includes after.err, "warning: moved #{message} to refused/: message format 1"
    assert_path_exists outbox('refused', "#{id}.json")
    assert_equal 'refused', store.outbox.outcome('zeus', id)['status']
  end

  private

  # A message to port.dev@zeus, which zeus has not answered yet, and whose outcome file holds no decision to keep, so
  # the forward that settles it repairs the file under the outcomes lock.
  def undecided_outcome
    orq = join_claude('orq.dev', 111)
    port = zeus
    remote.down << 'zeus'
    keryx('send', 'port.dev@zeus', 'hello', env: orq)
    id = store.outbox.queued('zeus').first.id
    File.write(outbox('receipts', "#{id}.outcome"), UNDECIDED)
    remote.down.clear
    [id, port]
  end

  def outbox(*parts) = tmp('state', 'outbox', 'zeus', *parts)

  def outbox_files
    Dir.glob('**/*', base: outbox).select { File.file?(outbox(it)) }.sort
  end

  def old_message(id)
    { 'keryx' => 1, 'id' => id, 'kind' => 'request', 'from' => 'orq@athena', 'to' => 'port@zeus', 'thread' => id,
      'in_reply_to' => nil, 'created_at' => NOW.iso8601, 'due_at' => (NOW + 60).iso8601, 'body' => 'Written before' }
  end

  def zeus
    alive << 333
    machine('zeus').merge(claude(333)).tap { keryx('join', 'port.dev', env: it) }
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
