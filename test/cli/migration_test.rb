# frozen_string_literal: true

require 'test_helper'

class MigrationTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include FlatAddresses

  FIXTURES = File.expand_path('../fixtures/context', __dir__)
  OLD_REFUSAL = { 'status' => 'refused', 'detail' => 'not a keryx message' }.freeze

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

  def test_new_mail_from_a_team_address_reaches_a_flat_address_in_the_new_format
    orq = join_claude('orq.dev', 111)
    unheld('person')
    sent = [%w[send person@athena hello], %w[ask person@athena hello]].map { keryx(*it, env: orq) }

    assert_equal([[0, '']] * 2, sent.map { [it.status, it.err] })
    assert_equal [2, 2], stored_formats('person')
  end

  def test_a_session_on_a_flat_address_answers_in_its_threads_in_the_old_format
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

  def test_a_session_on_a_flat_address_starts_new_work_with_a_team_address
    join_claude('orq.dev', 111)
    rev = held('rev-1', 222)
    sent = [%w[ask orq.dev hello], %w[send orq.dev hello]].map { keryx(*it, env: rev) }

    assert_equal([[0, '']] * 2, sent.map { [it.status, it.err] })
    assert_equal(['rev-1@athena'] * 2, store.mailbox('orq.dev').map { it.message.from })
  end

  def test_keryx_notices_reach_a_flat_address_nobody_holds_from_the_sender_keryx_had_then
    path = tmp('home', '.claude', 'projects', '-work', 'session-300.jsonl')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, File.read(File.join(FIXTURES, 'claude-transcript.jsonl')).gsub('"session-1"', '"session-300"'))
    alive << 300
    keryx('join', 'impl.dev', '--ceiling', '125k', env: claude(300))
    unheld('orq')
    impl = flatten('impl.dev')
    store.bind(impl, store.occupant(impl).with(director: 'orq'))
    courier = keryx('courier', '--once')

    assert_equal '', courier.err
    assert_equal([['keryx@athena']] * 2, %w[impl orq].map { |name| store.mailbox(name).map { it.message.from } })
    assert_equal([[1], [1]], %w[impl orq].map { stored_formats(it) })
  end

  def received_on_zeus(*messages)
    lines = messages.map { "#{it.to_json}\n" }.join
    receipts = keryx('__receive', env: machine('zeus'), input: lines).out.lines.map { JSON.parse(it) }
    receipts.map { it.values_at('status', 'detail') }
  end

  def test_another_machine_takes_new_mail_to_and_from_a_flat_address
    flat_threads_on_zeus
    Keryx::Store.new(tmp('zeus')).create_address('rev.dev')
    receipts = received_on_zeus(flat_request(from: 'orq@athena', to: 'port@zeus'),
                                build_message(from: 'orq@athena', to: 'port@zeus'),
                                build_message(from: 'orq.dev@athena', to: 'port@zeus', kind: 'request'),
                                build_message(from: 'orq@athena', to: 'rev.dev@zeus', kind: 'request'))

    assert_equal([['delivered', nil]] * 4, receipts)
  end

  # A reply answers any message of its thread, and one in a thread that is over or that zeus never had still arrives.
  def test_another_machine_takes_mail_to_a_flat_address_in_any_thread
    asked, received = flat_threads_on_zeus
    reply = build_message(from: asked.to, to: asked.from, kind: 'reply', in_reply_to: asked.id, thread: asked.thread)
    invented = Keryx::Ulid.generate
    receipts = received_on_zeus(reply, reply,
                                build_message(from: asked.to, to: asked.from, kind: 'reply', in_reply_to: asked.id,
                                              thread: asked.thread),
                                build_message(from: received.from, to: received.to, kind: 'withdrawal',
                                              in_reply_to: received.id, thread: received.thread),
                                build_message(from: 'orq@athena', to: 'port@zeus', kind: 'reply', in_reply_to: invented,
                                              thread: invented))

    assert_equal([['delivered', nil], ['duplicate', nil]] + ([['delivered', nil]] * 3), receipts)
    assert_equal 5, Keryx::Store.new(tmp('zeus')).stored('port').size
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
