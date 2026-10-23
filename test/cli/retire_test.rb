# frozen_string_literal: true

require 'test_helper'

class RetireTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  RETIRED = "error: rev-1.dev@athena is retired; mail to it is refused\n"

  def setup
    super
    @orq = join_claude('orq.dev', 111)
    @rev = join_claude('rev-1.dev', 222)
  end

  def asked(recipient, text, env:) = keryx('ask', recipient, text, env:).out[/\AAsked \S+ \((\w{26})\)/, 1]

  def retired
    alive.delete(222)
    result = keryx('retire', 'rev-1.dev')
    raise "retire failed: #{result.err}" unless result.status.zero?

    result
  end

  def test_retire_refuses_an_address_another_live_session_holds
    result = keryx('retire', 'rev-1.dev')

    assert_equal 1, result.status
    assert_equal 'error: rev-1.dev@athena is held by another live claude session (pid 222); that session releases it ' \
                 "with 'keryx leave', and once it ends 'keryx retire rev-1.dev' works\n", result.err
    refute store.retired?('rev-1.dev')
  end

  def test_retire_refuses_the_address_the_session_running_it_holds
    result = keryx('retire', 'rev-1.dev', env: @rev)

    assert_equal 1, result.status
    assert_equal "error: this session holds rev-1.dev@athena; release it with 'keryx leave' first\n", result.err
  end

  def test_retire_refuses_while_requests_wait_either_way_and_says_how_to_settle_each
    received = asked('rev-1.dev', 'Review PR #448', env: @orq)
    sent = asked('orq.dev', 'Which branch?', env: @rev)
    alive.delete(222)
    result = keryx('retire', 'rev-1.dev')

    assert_equal 1, result.status
    assert_equal "error: rev-1.dev@athena has 2 open requests and retires once none is left: #{received} from " \
                 "orq.dev@athena waits for its answer ('keryx reply #{received} --as rev-1.dev', or its sender " \
                 "withdraws it); #{sent} it sent to orq.dev@athena waits for a reply ('keryx withdraw #{sent} " \
                 "--as rev-1.dev')\n", result.err
    keryx('reply', received, 'Done', '--as', 'rev-1.dev')

    assert_match(/rev-1.dev@athena has 1 open request and retires once none is left: #{sent} it sent/,
                 keryx('retire', 'rev-1.dev').err)
    keryx('withdraw', sent, '--as', 'rev-1.dev')

    assert_equal 0, keryx('retire', 'rev-1.dev').status
  end

  def test_retire_refuses_the_person_another_machine_an_unknown_name_and_a_retired_address
    retired
    refusals = [%w[person], %w[port.dev@zeus], %w[ghost.dev], %w[rev-1.dev]].map { keryx('retire', *it).err }

    assert_equal ['error: person.local@athena is the address a plain terminal on athena acts as, ' \
                  'so it cannot be retired',
                  "error: retire runs on the machine that holds the address; run 'keryx retire port.dev' on zeus",
                  'error: no address ghost.dev@athena',
                  'error: rev-1.dev@athena is retired already, since 2026-10-22 17:00:00 UTC by person.local@athena'],
                 refusals.map(&:chomp)
    assert_equal 2, keryx('retire').status
  end

  def test_retire_keeps_the_files_and_says_where_they_are
    keryx('send', 'rev-1.dev', 'heads-up', env: @orq)
    alive.delete(222)
    result = keryx('retire', 'rev-1.dev@athena')

    assert_equal "Retired rev-1.dev@athena. Its files stay in #{tmp('state', 'addresses', 'rev-1.dev')}, and 'keryx " \
                 "join rev-1.dev --revive' brings it back with its mailbox.\n", result.out
    assert_equal({ 'retired_at' => '2026-10-22T17:00:00Z', 'by' => 'person.local@athena' },
                 JSON.parse(File.read(tmp('state', 'addresses', 'rev-1.dev', 'retired.json'))))
    assert_equal(['heads-up'], store.mailbox('rev-1.dev').map { it.message.body })
    assert_nil store.occupant('rev-1.dev')
  end

  def test_a_retired_address_with_unread_mail_leaves_who_and_status
    keryx('send', 'rev-1.dev', 'heads-up', env: @orq)
    retired
    status = JSON.parse(keryx('status', '-o', 'json').out)

    refute_includes keryx('who').out, 'rev-1@'
    refute_includes keryx('who', '--all').out, 'rev-1@'
    refute_includes status['addresses'].map { it['address'] }, 'rev-1.dev@athena'
    refute_includes keryx('status', '--all').out, 'rev-1@'
    assert_empty status['not_rung']
  end

  def test_mail_to_a_retired_address_is_refused
    retired
    results = [keryx('send', 'rev-1.dev', 'hello', env: @orq), keryx('ask', 'rev-1.dev@athena', 'Review it', env: @orq)]

    assert_equal([[1, RETIRED]] * 2, results.map { [it.status, it.err] })
    assert_empty store.mailbox('rev-1.dev')
  end

  # The reply to a request the address sent is in its own mailbox, which status still reads.
  def test_a_request_it_sent_and_had_answered_stays_answered
    id = asked('orq.dev', 'Which branch?', env: @rev)
    keryx('reply', id, 'main', env: @orq)
    retired

    assert_empty JSON.parse(keryx('status', '-o', 'json').out)['open_requests']
  end

  def test_join_refuses_a_retired_address
    retired
    alive << 333
    refused = keryx('join', 'rev-1.dev', env: claude(333))

    assert_equal [1, "error: rev-1.dev@athena is retired; pass --revive to bring it back with its mailbox\n"],
                 [refused.status, refused.err]
    assert store.retired?('rev-1.dev')
  end

  def test_join_revive_brings_the_address_back_with_its_mail
    keryx('send', 'rev-1.dev', 'heads-up', env: @orq)
    retired
    alive << 333
    revived = keryx('join', 'rev-1.dev', '--revive', env: claude(333))

    assert_equal 0, revived.status
    assert_match(/^1 unread message\(s\) waiting/, revived.out)
    refute store.retired?('rev-1.dev')
    assert_includes keryx('who').out, 'rev-1.dev@athena'
    assert_equal 0, keryx('join', 'orq.dev', '--revive', '--force', env: claude(333)).status
  end

  def test_acting_as_a_retired_address_is_refused
    retired
    result = keryx('inbox', '--as', 'rev-1.dev')

    assert_equal [1, "error: rev-1.dev@athena is retired; 'keryx join rev-1.dev --revive' brings it back\n"],
                 [result.status, result.err]
  end

  # A session restarted in the pane of the old holder would take the address back by its pane if its record stayed.
  def test_a_session_restarted_in_the_old_pane_does_not_take_a_retired_address_back
    pane = { 'HERDR_SOCKET_PATH' => '/h.sock', 'HERDR_PANE_ID' => 'w1:p2' }
    keryx('join', 'rev-1.dev', env: @rev.merge(pane))
    retired
    alive << 333
    result = keryx('inbox', env: claude(333).merge(pane))

    assert_equal 1, result.status
    assert_match(/this claude session holds no address/, result.err)
  end

  def test_another_machine_learns_that_the_address_is_retired
    alive << 333
    keryx('join', 'port.dev', env: machine('zeus').merge(claude(333)))
    alive.delete(333)
    keryx('retire', 'port.dev', env: machine('zeus'))
    sent = keryx('send', 'port.dev@zeus', 'hello', env: @orq)

    assert_equal "error: zeus refused the message; port.dev@zeus is retired; mail to it is refused\n", sent.err
    remote.down << 'zeus'
    keryx('send', 'port.dev@zeus', 'still there?', env: @orq)
    remote.down.clear
    keryx('courier', '--once')
    refused = JSON.parse(keryx('status', '-o', 'json').out)['not_forwarded']

    assert_equal([['port.dev@zeus', 'refused', 'port.dev@zeus is retired; mail to it is refused']],
                 refused.map { it.values_at('to', 'state', 'detail') })
    refute_includes keryx('who', env: machine('zeus')).out, 'port@'
  end
end
