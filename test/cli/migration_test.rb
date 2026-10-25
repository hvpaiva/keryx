# frozen_string_literal: true

require 'test_helper'

class MigrationTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  FIXTURES = File.expand_path('../fixtures/context', __dir__)
  OLD_REFUSAL = { 'status' => 'refused', 'detail' => 'not a keryx message' }.freeze

  # Gives an address the flat name and the record a keryx from before team names wrote, and returns that name.
  def flatten(key, state: tmp('state'))
    name = key.split('.').first
    File.rename(File.join(state, 'addresses', key), File.join(state, 'addresses', name))
    File.write(File.join(state, 'addresses', name, 'address.json'),
               JSON.generate('name' => name, 'created_at' => NOW.iso8601))
    name
  end

  # An address as a keryx from before team names left it, with no session holding it.
  def unheld(name)
    store.create_address("#{name}.old")
    flatten("#{name}.old")
  end

  # A session that joined NAME before team names, holding it still.
  def held(name, pid)
    env = join_claude("#{name}.dev", pid)
    flatten("#{name}.dev")
    env
  end

  def flat_request(from:, to:)
    build_message(from:, to:, kind: 'request', body: 'Review PR #448', id: Keryx::Ulid.generate(NOW))
  end

  # A keryx from before team addresses takes message format 1 and refuses any other, as it always has.
  def old_peer
    @formats = []
    @remote = FakeRemote.new do |_host, input|
      input.lines.map { JSON.parse(it) }.map do |line|
        @formats << line['keryx']
        receipt = line['keryx'] == 1 ? { 'status' => 'delivered' } : OLD_REFUSAL
        "#{JSON.generate(receipt.merge('id' => line['id']))}\n"
      end.join
    end
  end

  def stored_formats(name)
    Dir[tmp('state', 'addresses', name, 'mail', '*.json')].map { JSON.parse(File.read(it))['keryx'] }
  end

  def test_who_and_status_give_a_flat_address_no_team_and_no_session_address
    held('orq', 111)
    unheld('person')
    fields = %w[address member team host session_address]
    rows = %w[who status].map { |command| JSON.parse(keryx(command, '--all', '-o', 'json').out)['addresses'] }

    assert_equal([[['orq@athena', 'orq', nil, 'athena', nil], ['person@athena', 'person', nil, 'athena', nil]]] * 2,
                 rows.map { |records| records.map { it.values_at(*fields) } })
  end

  def test_new_mail_to_a_flat_address_is_refused_with_the_spelling_to_use
    orq = join_claude('orq.dev', 111)
    unheld('person')
    refusals = [%w[send person@athena hello], %w[ask person@athena hello]].map { keryx(*it, env: orq) }

    assert_equal([[1, 'error: person@athena has no team: an address is MEMBER.TEAM@HOST, such as person.TEAM@athena, ' \
                      "and a person at a terminal is person.local@athena\n"]] * 2,
                 refusals.map { [it.status, it.err] })
    assert_empty store.mailbox('person')
  end

  def test_a_session_on_a_flat_address_finishes_its_threads_in_the_old_format
    unheld('orq')
    rev = held('rev-1', 222)
    request = flat_request(from: 'orq@athena', to: 'rev-1@athena')
    store.deliver('rev-1', request)
    taken = keryx('send', '--re', request.id, 'On it', env: rev)
    clock.advance(1)
    replied = keryx('reply', request.id, 'Done', env: rev)
    inbox = JSON.parse(keryx('inbox', '--as', 'orq@athena', '-o', 'json').out)

    assert_equal [0, 0], [taken.status, replied.status]
    assert_equal(['On it', 'Done'], inbox.map { it['body'] })
    assert_equal [1, 1], stored_formats('orq')
  end

  def test_a_session_on_a_flat_address_starts_no_new_work
    join_claude('orq.dev', 111)
    rev = held('rev-1', 222)
    refusals = [%w[ask orq.dev hello], %w[send orq.dev hello]].map { keryx(*it, env: rev) }
    refusal = 'error: rev-1@athena is an address from before team names: it finishes its open requests and starts ' \
              "no new work; join MEMBER.TEAM for new work, and 'keryx retire rev-1@athena' once none is open\n"

    assert_equal([refusal] * 2, refusals.map(&:err))
    assert_empty store.mailbox('orq.dev')
  end

  def test_keryx_notices_reach_a_flat_address_only_while_a_session_here_holds_it
    path = tmp('home', '.claude', 'projects', '-work', 'session-300.jsonl')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, File.read(File.join(FIXTURES, 'claude-transcript.jsonl')).gsub('"session-1"', '"session-300"'))
    alive << 300
    keryx('join', 'impl.dev', '--ceiling', '125k', env: claude(300))
    unheld('orq')
    impl = flatten('impl.dev')
    store.bind(impl, store.occupant(impl).with(director: 'orq'))
    courier = keryx('courier', '--once')

    assert_equal ["told impl@athena that impl@athena is at 121k 97% of 125k, near its context ceiling\n", ''],
                 [courier.out, courier.err]
    assert_equal(['keryx.system@athena'], store.mailbox('impl').map { it.message.from })
    assert_empty store.mailbox('orq')
  end

  # On zeus, port@zeus asked orq@athena for a review before team names, and holds a request orq@athena sent it.
  def flat_threads_on_zeus
    alive << 333
    keryx('join', 'port.dev', env: machine('zeus').merge(claude(333)))
    flatten('port.dev', state: tmp('zeus'))
    zeus = Keryx::Store.new(tmp('zeus'))
    [flat_request(from: 'port@zeus', to: 'orq@athena').tap { zeus.outbox.queue('athena', it) },
     flat_request(from: 'orq@athena', to: 'port@zeus').tap { zeus.deliver('port', it) }]
  end

  def received_on_zeus(*messages)
    lines = messages.map { "#{it.to_json}\n" }.join
    receipts = keryx('__receive', env: machine('zeus'), input: lines).out.lines.map { JSON.parse(it) }
    receipts.map { it.values_at('status', 'detail') }
  end

  def flat_refusal(address)
    "#{address} is an address from before team names: it takes only replies, withdrawals and messages in its open " \
      'threads'
  end

  def test_another_machine_takes_only_the_messages_that_finish_a_flat_addresss_threads
    asked, received = flat_threads_on_zeus
    answer = lambda do |kind|
      build_message(from: asked.to, to: asked.from, kind:, in_reply_to: asked.id, thread: asked.thread)
    end
    receipts = received_on_zeus(flat_request(from: 'orq@athena', to: 'port@zeus'), answer.call('message'),
                                answer.call('reply'),
                                build_message(from: 'orq@athena', to: 'port@zeus', kind: 'withdrawal',
                                              in_reply_to: received.id, thread: received.thread),
                                build_message(from: 'orq.dev@athena', to: 'port@zeus'))

    assert_equal([['refused', flat_refusal('orq@athena')], ['delivered', nil], ['delivered', nil], ['delivered', nil],
                  ['refused', flat_refusal('port@zeus')]], receipts)
  end

  def test_another_machine_refuses_mail_to_a_flat_address_in_a_thread_it_never_had
    asked, received = flat_threads_on_zeus
    invented = Keryx::Ulid.generate
    in_thread = lambda do |kind, of, from: 'orq@athena'|
      build_message(from:, to: 'port@zeus', kind:, in_reply_to: of, thread: of, body: 'New unrelated work')
    end
    receipts = received_on_zeus(in_thread.call('request', invented), in_thread.call('reply', invented),
                                in_thread.call('message', invented), in_thread.call('request', received.id),
                                in_thread.call('reply', asked.id, from: 'rev.dev@athena'))

    assert_equal(([['refused', flat_refusal('orq@athena')]] * 4) + [['refused', flat_refusal('port@zeus')]], receipts)
    assert_equal([received.id], Keryx::Store.new(tmp('zeus')).stored('port').map { it.message.id })
  end

  # Here a reply from orq@athena closes the request port@zeus asked, and one from port@zeus the request it received.
  def test_another_machine_gives_a_flat_address_nothing_new_in_a_thread_that_is_over
    asked, received = flat_threads_on_zeus
    zeus = Keryx::Store.new(tmp('zeus'))
    zeus.outbox.queue('athena', build_message(from: received.to, to: received.from, kind: 'reply',
                                              in_reply_to: received.id, thread: received.thread))
    answer = lambda do |kind|
      build_message(from: asked.to, to: asked.from, kind:, in_reply_to: asked.id, thread: asked.thread)
    end
    reply = answer.call('reply')
    receipts = received_on_zeus(reply, reply, answer.call('message'), answer.call('reply'),
                                build_message(from: received.from, to: received.to, kind: 'withdrawal',
                                              in_reply_to: received.id, thread: received.thread))

    assert_equal([['delivered', nil], ['duplicate', nil]] + ([['refused', flat_refusal('orq@athena')]] * 3), receipts)
    assert_equal([received.id, reply.id].sort, zeus.stored('port').map { it.message.id }.sort)
  end

  def test_an_old_keryx_elsewhere_refuses_format_2_for_good_and_says_why
    orq = join_claude('orq.dev', 111)
    old_peer
    sent = keryx('send', 'port.dev@zeus', 'hello', env: orq)
    remote.down << 'zeus'
    keryx('send', 'port.dev@zeus', 'still there?', env: orq)
    remote.down.clear
    courier = keryx('courier', '--once')
    refused = JSON.parse(keryx('status', '-o', 'json').out)['not_forwarded']
    reason = 'zeus runs a keryx from before team addresses, which refuses message format 2; upgrade keryx on zeus ' \
             'and send again'

    assert_equal "error: zeus refused the message; #{reason}\n", sent.err
    assert_match(/\Azeus refused \w+: #{Regexp.escape(reason)}\n\z/, courier.out)
    assert_equal([['port.dev@zeus', 'refused', reason]], refused.map { it.values_at('to', 'state', 'detail') })
    assert_empty keryx('courier', '--once').out
  end

  def test_an_old_keryx_elsewhere_still_takes_the_replies_that_finish_old_threads
    old_peer
    unheld('orq')
    request = flat_request(from: 'port@zeus', to: 'orq@athena')
    store.deliver('orq', request)
    replied = keryx('reply', request.id, 'Done', '--as', 'orq@athena')

    assert_equal [0, ''], [replied.status, replied.err]
    assert_match(/\AReplied to port@zeus \(\w+\)\. It reached zeus/, replied.out)
    assert_equal [1], @formats
  end
end
