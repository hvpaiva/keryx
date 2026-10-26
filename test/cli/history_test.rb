# frozen_string_literal: true

require 'test_helper'

class HistoryTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  ISO_TIME = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/
  BOX = %w[read receipts tmp].freeze

  def setup
    super
    @orq = join_claude('orq.dev', 111)
    @rev = join_claude('rev-1.dev', 222)
  end

  def history(*argv)
    run = keryx('history', *argv, '-o', 'json')

    assert_equal ['', 0], [run.err, run.status]
    JSON.parse(run.out)
  end

  # rev leaves and orq retires it, so nothing here acts as the person at the terminal.
  def retire_rev
    keryx('leave', env: @rev)
    result = keryx('retire', 'rev-1.dev', env: @orq)
    raise "retire failed: #{result.err}" unless result.status.zero?
  end

  def snapshot(root)
    Dir.glob('**/*', base: root).sort.to_h do |path|
      full = File.join(root, path)
      [path, File.file?(full) ? [File.read(full), File.mtime(full)] : File.mtime(full)]
    end.merge('.' => File.mtime(root))
  end

  def raw(path, data)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.write(path, JSON.generate(data))
  end

  def id(seconds) = Keryx::Ulid.generate(NOW + seconds)

  # The format 2 keys exactly, with format 1 and addresses with no team, as a keryx from before team names wrote them.
  def old_message(id, from:, to:, kind: 'message')
    { 'keryx' => 1, 'id' => id, 'kind' => kind, 'from' => from, 'to' => to, 'thread' => id, 'in_reply_to' => nil,
      'created_at' => NOW.iso8601, 'due_at' => nil, 'body' => "Written before team names, a #{kind}" }
  end

  def old_mail(name, id) = tmp('state', 'addresses', name, 'mail', "#{id}.json")

  # hvpaiva@athena, retired, and port@athena, which nobody retired, as old_store_test builds them: hvpaiva read the
  # first of two messages from port, and port holds a request from hvpaiva.
  def old_folders
    %w[hvpaiva port].each do |name|
      raw(tmp('state', 'addresses', name, 'address.json'), 'name' => name, 'role' => 'human',
                                                           'created_at' => NOW.iso8601)
      BOX.each { FileUtils.mkdir_p(tmp('state', 'addresses', name, it)) }
    end
    raw(tmp('state', 'addresses', 'hvpaiva', 'retired.json'), 'retired_at' => NOW.iso8601, 'by' => 'orq@athena')
    first, second, request = (1..3).map { id(it) }
    [first, second].each { raw(old_mail('hvpaiva', it), old_message(it, from: 'port@athena', to: 'hvpaiva@athena')) }
    File.link(old_mail('hvpaiva', first), tmp('state', 'addresses', 'hvpaiva', 'read', "#{first}.json"))
    raw(old_mail('port', request), old_message(request, from: 'hvpaiva@athena', to: 'port@athena', kind: 'request'))
    [first, second, request]
  end

  def old_trees = %w[hvpaiva port].to_h { [it, snapshot(tmp('state', 'addresses', it))] }

  def test_a_retired_address_lists_its_whole_mailbox_with_states_and_marks_nothing
    keryx('ask', 'rev-1.dev', 'Review it', env: @orq)
    request = last_id(@rev)
    clock.advance(1)
    keryx('send', 'rev-1.dev', 'Heads-up', env: @orq)
    keryx('reply', request, 'Done', env: @rev)
    inbox = JSON.parse(keryx('inbox', '--all', '-o', 'json', env: @rev).out)
    retire_rev
    read = snapshot(tmp('state', 'addresses', 'rev-1.dev', 'read'))
    listed = history('rev-1.dev')
    table = keryx('history', 'rev-1.dev@athena').out

    assert_equal inbox, listed
    assert_equal([%w[request read], %w[message unread]], listed.map { it.values_at('kind', 'state') })
    assert_match(/^ID +KIND +FROM +AGE +DUE +STATE +SUMMARY\n/, table)
    assert_match(/ message +orq\.dev@athena +0s +- +unread +Heads-up\n/, table)
    assert_equal read, snapshot(tmp('state', 'addresses', 'rev-1.dev', 'read'))
  end

  def test_a_folder_from_before_team_names_lists_by_member_at_host_retired_or_not_and_stays_as_written
    first, second, request = old_folders
    before = old_trees
    retired = history('hvpaiva@athena')
    kept = history('port@athena')
    table = keryx('history', 'hvpaiva@athena')

    assert_equal([[first, 'read'], [second, 'unread']], retired.map { it.values_at('id', 'state') })
    assert_equal([%w[port@athena hvpaiva@athena]] * 2, retired.map { it.values_at('from', 'to') })
    assert_equal([[request, 'request', 'unread', nil]],
                 kept.map { it.values_at('id', 'kind', 'state', 'withdrawn_by') })
    assert_equal ['', 3], [table.err, table.out.lines.size]
    assert_equal before, old_trees
  end

  def test_an_address_not_retired_one_on_another_machine_and_an_unknown_one_are_refused
    argvs = [%w[rev-1.dev], %w[rev-1.dev --sent], %w[port.dev@zeus], %w[port@zeus], %w[ghost.dev], %w[ghost@athena],
             %w[..@athena]]

    assert_equal(["rev-1.dev@athena is not retired; 'keryx inbox --all --as rev-1.dev' lists it",
                  "rev-1.dev@athena is not retired; 'keryx sent --as rev-1.dev' lists what it sent",
                  "port.dev@zeus is on another machine; run 'keryx history port.dev@zeus' on zeus",
                  "port@zeus is on another machine; run 'keryx history port@zeus' on zeus",
                  'no address ghost.dev@athena', 'no address ghost@athena',
                  'invalid name "..": a lowercase letter, then up to 31 lowercase letters, digits or hyphens, with ' \
                  '.TEAM spelled the same'].map { [1, "error: #{it}\n"] },
                 argvs.map { keryx('history', *it).then { |run| [run.status, run.err] } })
  end

  def test_a_bare_member_one_session_and_a_filter_without_sent_are_refused
    session = store.occupant('rev-1.dev').session
    retire_rev
    usage = "Run 'keryx history --help' for usage.\n"
    runs = [%w[rev-1], ["rev-1.dev/#{session}"], %w[rev-1.dev --to orq]].map { keryx('history', *it) }

    assert_equal([[2, 'error: history takes MEMBER.TEAM, MEMBER.TEAM@HOST, or MEMBER@HOST for an address from ' \
                      "before team names; rev-1 names neither\n#{usage}"],
                  [1, "error: rev-1.dev@athena/#{session} is one session of rev-1.dev@athena, and history takes " \
                      "only the address itself\n"],
                  [2, "error: --id, --thread and --to narrow what --sent lists; add --sent\n#{usage}"]],
                 runs.map { [it.status, it.err] })
  end

  def test_sent_lists_what_a_retired_team_address_sent
    keryx('send', 'orq.dev', 'From rev', env: @rev)
    keryx('read', last_id(@orq), env: @orq)
    remote.down << 'zeus'
    clock.advance(1)
    keryx('send', 'port.dev@zeus', 'Across', env: @rev)
    retire_rev
    sent = history('rev-1.dev', '--sent')

    assert_equal([%w[orq.dev@athena delivered], %w[port.dev@zeus queued]], sent.map { it.values_at('to', 'delivery') })
    assert_match ISO_TIME, sent.first['read_at']
    refute_includes sent.last.keys, 'read_at'
    assert_equal(['From rev'], history('rev-1.dev', '--sent', '--to', 'orq').map { it['body'] })
  end

  def test_sent_lists_the_format_1_mail_an_address_from_before_team_names_sent
    _, _, request = old_folders
    forwarded, refused = [4, 5].map { id(it) }
    outbox = tmp('state', 'outbox', 'zeus')
    raw(File.join(outbox, 'cur', "#{forwarded}.json"), old_message(forwarded, from: 'hvpaiva@athena', to: 'port@zeus'))
    raw(File.join(outbox, 'refused', "#{refused}.json"), old_message(refused, from: 'hvpaiva@athena', to: 'port@zeus'))
    before = old_trees
    sent = history('hvpaiva@athena', '--sent')

    assert_equal([[request, 'port@athena', 'delivered'], [forwarded, 'port@zeus', 'forwarded'],
                  [refused, 'port@zeus', 'refused']], sent.map { it.values_at('id', 'to', 'delivery') })
    assert_equal([[true, nil], [false, nil], [false, nil]], sent.map { [it.key?('read_at'), it['read_at']] })
    assert_equal([request], history('hvpaiva@athena', '--sent', '--to', 'port@athena').map { it['id'] })
    assert_empty JSON.parse(keryx('status', '-o', 'json').out)['not_forwarded']
    assert_equal before, old_trees
  end

  def test_history_from_a_plain_terminal_creates_no_address_for_the_person
    keryx('send', 'rev-1.dev', 'heads-up', env: @orq)
    retire_rev
    old_folders
    runs = [%w[rev-1.dev], %w[rev-1.dev --sent --to orq], %w[hvpaiva@athena --sent], %w[ghost@athena]]
           .map { keryx('history', *it) }

    assert_equal [0, 0, 0, 1], runs.map(&:status)
    refute store.address?('person.local')
    refute_path_exists tmp('state', 'addresses', 'person.local')
  end

  def test_completion_offers_the_retired_addresses_and_no_folder_from_before_team_names
    old_folders
    retire_rev

    assert_equal %w[rev-1.dev], keryx('__complete', 'history', '').out.lines(chomp: true)
    assert_includes keryx('__complete', 'history', '-').out.lines(chomp: true), '--sent'
  end
end
