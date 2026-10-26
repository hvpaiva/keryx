# frozen_string_literal: true

require 'test_helper'

# A store that a keryx from before team names left, written file by file as that keryx wrote it: folders named MEMBER
# with a record that has a name, mail of format 1 between two such addresses, and of format 2 when one end has a team.
class OldStoreTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def raw(path, data)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.write(path, JSON.generate(data))
  end

  def old_message(id, from:, to:, kind: 'request', format: 1)
    { 'keryx' => format, 'id' => id, 'kind' => kind, 'from' => from, 'to' => to, 'thread' => id, 'in_reply_to' => nil,
      'created_at' => NOW.iso8601, 'due_at' => (NOW + 60).iso8601, 'body' => 'Written before team names' }
  end

  def id(seconds) = Keryx::Ulid.generate(NOW + seconds)

  def teamless(address)
    "#{address} is an address from before team names, which keryx no longer writes to or takes mail from"
  end

  # hvpaiva@athena, retired, and port@athena, which nobody retired, with a request between them.
  def old_folders
    %w[hvpaiva port].each do |name|
      raw(tmp('state', 'addresses', name, 'address.json'), 'name' => name, 'role' => 'human',
                                                           'created_at' => NOW.iso8601)
      BOX.each { FileUtils.mkdir_p(tmp('state', 'addresses', name, it)) }
    end
    raw(tmp('state', 'addresses', 'hvpaiva', 'retired.json'), 'retired_at' => NOW.iso8601, 'by' => 'orq@athena')
    request = id(1)
    raw(tmp('state', 'addresses', 'port', 'mail', "#{request}.json"),
        old_message(request, from: 'hvpaiva@athena', to: 'port@athena'))
  end

  BOX = %w[read receipts tmp].freeze

  def old_trees = %w[hvpaiva port].to_h { [it, snapshot(tmp('state', 'addresses', it))] }

  def snapshot(root)
    Dir.glob('**/*', base: root).sort.to_h do |path|
      full = File.join(root, path)
      [path, File.file?(full) ? [File.read(full), File.mtime(full)] : File.mtime(full)]
    end
  end

  def complete(*words) = keryx('__complete', *words).out.lines(chomp: true)

  def test_a_folder_from_before_team_names_leaves_who_status_and_completion
    join_claude('orq.dev', 111)
    old_folders
    who = JSON.parse(keryx('who', '--all', '-o', 'json').out)
    status = keryx('status', '--all', '-o', 'json')

    assert_equal(['orq.dev@athena'], who['addresses'].map { it['address'] })
    refute_match(/hvpaiva|"port@/, status.out)
    assert_empty JSON.parse(status.out)['open_requests']
    assert_empty status.err
    assert_equal %w[orq.dev], complete('--as', '')
  end

  def test_a_folder_from_before_team_names_is_never_read_moved_or_deleted
    orq = join_claude('orq.dev', 111)
    old_folders
    before = old_trees
    alive << 222
    joined = keryx('join', 'port', env: claude(222))
    runs = [keryx('courier', '--once'), keryx('ring'), keryx('inbox', '--all', env: orq), keryx('who', '--all')]

    assert_equal 'error: no address port.TEAM on athena; name the team, as port.TEAM', joined.err.strip
    assert_equal(['', '', '', ''], runs.map(&:err))
    assert_equal before, old_trees
  end

  def test_a_name_from_before_team_names_typed_by_a_user_is_refused_with_its_reason
    orq = join_claude('orq.dev', 111)
    old_folders
    reason = 'hvpaiva@athena has no team: an address is MEMBER.TEAM@HOST, such as hvpaiva.TEAM@athena, and a ' \
             'person at a terminal is hvpaiva.local@athena'
    runs = [%w[send hvpaiva@athena hello], %w[ask hvpaiva@athena hello], %w[join hvpaiva@athena],
            %w[join hvpaiva@athena --revive], %w[retire hvpaiva@athena], %w[ring hvpaiva@athena],
            %w[inbox --as hvpaiva@athena], %w[withdraw 01M5 --as hvpaiva@athena]]

    runs.each do |argv|
      result = keryx(*argv, env: orq)

      assert_equal [1, "error: #{reason}\n"], [result.status, result.err], argv.join(' ')
    end
    assert_match(/\Aerror: port@zeus has no team: /, keryx('send', 'port@zeus', 'hello', env: orq).err)
    assert_empty Dir[tmp('state', 'outbox', '*', '*', '*.json')]
  end

  def test_stored_mail_from_an_address_from_before_team_names_still_reads_and_its_request_is_over
    orq = join_claude('orq.dev', 111)
    request = id(1)
    raw(tmp('state', 'addresses', 'orq.dev', 'mail', "#{request}.json"),
        old_message(request, from: 'hvpaiva@athena', to: 'orq.dev@athena', format: 2))
    listed = JSON.parse(keryx('inbox', '--all', '-o', 'json', env: orq).out)
    read = keryx('read', request, env: orq)
    answers = [keryx('reply', request, 'Done', env: orq), keryx('send', '--re', request, 'On it', env: orq)]

    assert_equal([[request, 'hvpaiva@athena']], listed.map { it.values_at('id', 'from') })
    assert_match(/from\s+hvpaiva@athena/, read.out)
    assert_equal([[1, "error: #{teamless('hvpaiva@athena')}\n"]] * 2, answers.map { [it.status, it.err] })
    assert_equal([request], store.stored('orq.dev').map { it.message.id })
    assert_empty JSON.parse(keryx('status', '-o', 'json').out)['open_requests']
    assert_empty keryx('hook', 'stop', env: orq, input: '{}').out
  end

  def test_a_request_sent_to_an_address_from_before_team_names_is_over_and_wait_says_so_at_once
    orq = join_claude('orq.dev', 111)
    request = id(1)
    raw(tmp('state', 'outbox', 'zeus', 'cur', "#{request}.json"),
        old_message(request, from: 'orq.dev@athena', to: 'port@zeus', format: 2))
    waited = keryx('wait', request, env: orq)

    assert_equal [1, "error: #{request} is over and gets no reply; #{teamless('port@zeus')}\n"],
                 [waited.status, waited.err]
    assert_empty JSON.parse(keryx('status', '-o', 'json').out)['open_requests']
    assert_equal "error: #{teamless('port@zeus')}\n", keryx('withdraw', request, env: orq).err
  end

  # Two files in new/ from before team names, one of format 1, and one of each in cur/ and refused/.
  def old_outbox
    outbox = tmp('state', 'outbox', 'zeus')
    old, flat, forwarded, refused = (1..4).map { id(it) }
    raw(File.join(outbox, 'new', "#{old}.json"), old_message(old, from: 'orq@athena', to: 'port@zeus'))
    raw(File.join(outbox, 'new', "#{flat}.json"), old_message(flat, from: 'orq.dev@athena', to: 'port@zeus', format: 2))
    raw(File.join(outbox, 'cur', "#{forwarded}.json"), old_message(forwarded, from: 'orq@athena', to: 'port@zeus'))
    raw(File.join(outbox, 'refused', "#{refused}.json"), old_message(refused, from: 'port@athena', to: 'port@zeus'))
    [old, flat, refused]
  end

  def zeus
    alive << 333
    machine('zeus').merge(claude(333)).tap { keryx('join', 'port.dev', env: it) }
  end

  def test_an_old_outbox_file_in_new_is_refused_once_with_its_reason
    orq = join_claude('orq.dev', 111)
    zeus
    old, flat, = old_outbox
    sent = keryx('send', 'port.dev@zeus', 'hello', env: orq)
    moved = ->(id) { "warning: moved #{tmp('state', 'outbox', 'zeus', 'new', "#{id}.json")} to refused/: " }

    assert_equal ["#{moved.call(old)}message format 1, of the addresses from before team names, is no longer taken",
                  "#{moved.call(flat)}#{teamless('port@zeus')}"], sent.err.lines(chomp: true)
    assert_equal([%w[refused] * 2, [nil] * 2], [old, flat].map { store.outbox.outcome('zeus', it) }
                                                         .map { it.values_at('status', 'bell') }.transpose)
    assert_empty keryx('courier', '--once').err
  end

  def test_old_outbox_files_hold_back_no_thread_and_cur_and_refused_skip_them_quietly
    orq = join_claude('orq.dev', 111)
    port = zeus
    refused = old_outbox
    keryx('send', 'port.dev@zeus', 'hello', env: orq)
    status = keryx('status', '-o', 'json')
    kept = Dir[tmp('state', 'outbox', 'zeus', 'refused', '*.json')].map { File.basename(it, '.json') }

    assert_equal [['zeus', [last_id(port)]]], remote.sent
    assert_equal refused.sort, kept.sort
    assert_empty status.err
    assert_equal([%w[port@zeus refused]], JSON.parse(status.out)['not_forwarded'].map { it.values_at('to', 'state') })
  end

  def test_a_message_from_another_machine_in_format_1_or_from_before_team_names_is_refused_with_its_reason
    store.create_address('orq.dev')
    receiver = Keryx::Receiver.new(store:, bell: nil, host: 'athena', person: 'person.local')
    old = id(1)
    flat = id(2)
    receipts = [receiver.receive(JSON.generate(old_message(old, from: 'port@zeus', to: 'orq@athena'))),
                receiver.receive(JSON.generate(old_message(flat, from: 'port@zeus', to: 'orq.dev@athena', format: 2)))]

    assert_equal [{ 'id' => old, 'status' => 'refused',
                    'detail' => 'message format 1, of the addresses from before team names, is no longer taken' },
                  { 'id' => flat, 'status' => 'refused',
                    'detail' => 'port@zeus is an address from before team names, which keryx no longer writes to or ' \
                                'takes mail from' }], receipts
    assert_empty store.stored('orq.dev')
  end
end
