# frozen_string_literal: true

# Holds an outbox lock of zeus from the test while a command runs, as another keryx command would, with the outbox
# messages the tests make. Include it after CLIHelpers.
module OutboxLocks
  BUSY = '%s stayed locked by another keryx command for 15s; try again, or end that command if it is stuck'
  UNDECIDED = '{"status":"maybe"}'

  def teardown
    @threads&.each { it.join(ProcessRaces::SECONDS) }
    super
  end

  private

  def outbox(*parts) = tmp('state', 'outbox', 'zeus', *parts)

  def outbox_files
    Dir.glob('**/*', base: outbox).select { File.file?(outbox(it)) }.sort
  end

  # A message to port.dev@zeus, which zeus has not answered yet, and whose outcome file holds no decision to keep, so
  # the forward that settles it repairs the file under the outcomes lock. It gives the id and the env of both ends.
  def undecided_outcome
    orq = join_claude('orq.dev', 111)
    port = zeus
    remote.down << 'zeus'
    keryx('send', 'port.dev@zeus', 'hello', env: orq)
    id = store.outbox.queued('zeus').first.id
    File.write(outbox('receipts', "#{id}.outcome"), UNDECIDED)
    remote.down.clear
    [id, port, orq]
  end

  # A message from before team names in new/, whose outcome file holds no decision, so a read of the queue that moves
  # it to refused/ repairs the file under the outcomes lock. It gives the message's path.
  def undecided_old_message
    id = Keryx::Ulid.generate(Factory::NOW)
    %w[tmp receipts new cur refused].each { FileUtils.mkdir_p(outbox(it), mode: 0o700) }
    File.write(outbox('new', "#{id}.json"), JSON.generate(old_message(id)))
    File.write(outbox('receipts', "#{id}.outcome"), UNDECIDED)
    outbox('new', "#{id}.json")
  end

  def old_message(id)
    { 'keryx' => 1, 'id' => id, 'kind' => 'request', 'from' => 'orq@athena', 'to' => 'port@zeus', 'thread' => id,
      'in_reply_to' => nil, 'created_at' => Factory::NOW.iso8601, 'due_at' => (Factory::NOW + 60).iso8601,
      'body' => 'Written before' }
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
