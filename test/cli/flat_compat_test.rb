# frozen_string_literal: true

require 'test_helper'

# Addresses from before team names work as they did then, beside team addresses, until each one is retired.
class FlatCompatTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include FlatAddresses

  # The kind and the format of each message in the mailbox of NAME.
  def formats(name, state: tmp('state'))
    Dir[File.join(state, 'addresses', name, 'mail', '*.json')].map do |path|
      JSON.parse(File.read(path)).values_at('kind', 'keryx')
    end.sort
  end

  def bodies_and_formats(state)
    Dir[File.join(state, 'addresses', '*', 'mail', '*.json')].map do |path|
      JSON.parse(File.read(path)).values_at('body', 'keryx')
    end
  end

  def test_a_session_joins_a_new_flat_address_written_as_keryx_wrote_it_before_team_names
    alive << 111
    joined = keryx('join', 'cp-rev-2@athena', '--role', 'reviewer', env: claude(111))

    assert_equal [0, ''], [joined.status, joined.err]
    assert_match(/\AJoined cp-rev-2@athena as a claude session/, joined.out)
    assert_equal(%w[created_at name role],
                 JSON.parse(File.read(tmp('state', 'addresses', 'cp-rev-2', 'address.json'))).keys.sort)
    assert_nil store.occupant('cp-rev-2').session
  end

  def test_join_force_takes_a_flat_address_from_a_live_session_as_before_team_names
    held('rev-1', 111)
    alive << 222
    forced = keryx('join', 'rev-1@athena', '--force', env: claude(222))
    who = JSON.parse(keryx('who', '-o', 'json').out)['addresses']

    assert_equal [0, ''], [forced.status, forced.err]
    refute_match(/stays reachable/, forced.out)
    assert_equal(['rev-1@athena'], who.map { it['address'] })
    assert_equal ['session-222', []], [store.occupant('rev-1').session_id, store.outgoing('rev-1')]
    assert_equal 1, keryx('whoami', env: claude(111)).status
  end

  def test_a_flat_address_is_left_and_released_for_a_session_that_ended
    rev = held('rev-1', 111)
    held('orq', 222)
    left = keryx('leave', env: rev)
    alive.delete(222)
    released = keryx('leave', '--as', 'orq@athena')

    assert_equal "Left rev-1@athena. Its mailbox keeps receiving.\n", left.out
    assert_match(/\AReleased orq@athena from its claude session .* Its mailbox keeps receiving\.\n\z/, released.out)
    assert_equal [nil, nil], [store.occupant('rev-1'), store.occupant('orq')]
  end

  def test_two_flat_addresses_here_ask_take_reply_and_wait_in_the_old_format
    orq = held('orq', 111)
    rev = held('rev-1', 222)
    asked = keryx('ask', 'rev-1@athena', 'Review PR #448', '--within', '1h', env: orq)
    id = last_id(rev)
    read = keryx('read', id, env: rev)
    taken = keryx('send', '--re', id, 'On it', env: rev)
    clock.advance(1)
    replied = keryx('reply', id, 'Approved', env: rev)
    waited = keryx('wait', id, env: orq)
    inbox = JSON.parse(keryx('inbox', '--all', '-o', 'json', env: orq).out)

    assert_equal([0] * 5, [asked, read, taken, replied, waited].map(&:status))
    assert_match(/Approved/, waited.out)
    assert_equal(['On it', 'Approved'], inbox.map { it['body'] })
    assert_equal [[['message', 1], ['reply', 1]], [['request', 1]]], [formats('orq'), formats('rev-1')]
  end

  def test_a_flat_address_withdraws_its_request_to_another_here_in_the_old_format
    orq = held('orq', 111)
    rev = held('rev-1', 222)
    keryx('ask', 'rev-1@athena', 'Review PR #448', env: orq)
    withdrawn = keryx('withdraw', last_id(rev), env: orq)

    assert_equal [0, ''], [withdrawn.status, withdrawn.err]
    assert_equal [['request', 1], ['withdrawal', 1]], formats('rev-1')
    assert_empty JSON.parse(keryx('status', '-o', 'json').out)['open_requests']
  end

  def test_a_flat_address_and_a_team_address_here_ask_and_reply_both_ways
    orq = held('orq', 111)
    rev = join_claude('rev-1.dev', 222)
    to_team = keryx('ask', 'rev-1.dev', 'Review it', env: orq)
    clock.advance(1)
    team_reply = keryx('reply', last_id(rev), 'Reviewed', env: rev)
    clock.advance(1)
    to_flat = keryx('ask', 'orq@athena', 'A question', env: rev)
    clock.advance(1)
    flat_reply = keryx('reply', last_id(orq), 'An answer', env: orq)

    assert_equal([[0, '']] * 4, [to_team, team_reply, to_flat, flat_reply].map { [it.status, it.err] })
    assert_equal [['reply', 2], ['request', 2]], formats('rev-1.dev')
    assert_equal [['reply', 2], ['request', 2]], formats('orq')
  end

  def test_between_machines_flat_to_flat_keeps_the_old_format_and_a_team_address_takes_the_new
    athena = { orq: held('orq', 111), rev: join_claude('rev-1.dev', 222) }
    flat_threads_on_zeus
    alive << 444
    zeus = { port: machine('zeus').merge(claude(333)), ops: machine('zeus').merge(claude(444)) }
    keryx('join', 'ops.dev', env: zeus[:ops])
    sent = [[athena[:orq], 'port@zeus', 'flat to flat'], [athena[:orq], 'ops.dev@zeus', 'flat to team'],
            [athena[:rev], 'port@zeus', 'team to flat'], [zeus[:port], 'orq@athena', 'flat to flat'],
            [zeus[:port], 'rev-1.dev@athena', 'flat to team'], [zeus[:ops], 'orq@athena', 'team to flat']]
           .map { |env, to, text| keryx('ask', to, text, env:) }
    expected = [['flat to flat', 1], ['flat to team', 2], ['team to flat', 2]]

    assert_equal([[0, '']] * 6, sent.map { [it.status, it.err] })
    assert_equal([expected] * 2, [tmp('zeus'), tmp('state')].map do |state|
      bodies_and_formats(state).select { it.first.include?(' to ') }.sort
    end)
  end

  def test_the_courier_tells_a_flat_sender_nobody_holds_that_its_deadline_passed
    join_claude('rev-1.dev', 222)
    unheld('author')
    keryx('ask', 'rev-1.dev', 'Review it', '--within', '1m', '--as', 'author@athena')
    clock.advance(120)
    courier = keryx('courier', '--once')
    notice = JSON.parse(keryx('inbox', '-o', 'json', '--as', 'author@athena').out).first

    assert_match(/\Atold author@athena that \w+ to rev-1.dev@athena is past its deadline\n/, courier.out)
    assert_equal ['keryx@athena', [['message', 1]]], [notice['from'], formats('author')]
  end

  def test_a_team_session_retires_a_flat_address_named_in_full
    orq = join_claude('orq.dev', 111)
    unheld('rev-1')
    retired = keryx('retire', 'rev-1@athena', env: orq)
    refused = keryx('send', 'rev-1@athena', 'hello', env: orq)

    assert_equal [0, ''], [retired.status, retired.err]
    assert store.retired?('rev-1')
    assert_match(/\Aerror: rev-1@athena is retired/, refused.err)
  end

  def test_ring_rings_a_flat_address
    held('rev-1', 222)
    store.deliver('rev-1', flat_request(from: 'orq@athena', to: 'rev-1@athena'))
    rung = keryx('ring', 'rev-1@athena')

    assert_equal [0, ''], [rung.status, rung.err]
    assert_equal '/tmp/cc-222.sock', sockets.posts.last.first
  end

  def test_an_unjoined_session_joins_a_new_flat_address_by_its_bare_name
    alive << 111
    joined = keryx('join', 'cp-rev-3', env: claude(111))

    assert_equal [0, ''], [joined.status, joined.err]
    assert_match(/\AJoined cp-rev-3@athena as a claude session/, joined.out)
  end

  def test_a_flat_sender_names_a_flat_address_by_its_bare_name_before_a_team_one
    orq = held('orq', 111)
    unheld('nomos')
    join_claude('nomos.dev', 222)
    sent = keryx('send', 'nomos', 'hello', env: orq)
    retired = keryx('retire', 'nomos', env: orq)
    moved = keryx('send', 'nomos', 'moved', env: orq)
    none = keryx('send', 'plat', 'hello', env: orq)

    assert_equal([[0, '']] * 3, [sent, retired, moved].map { [it.status, it.err] })
    assert_equal([['hello'], ['moved']], %w[nomos nomos.dev].map { |name| store.mailbox(name).map { it.message.body } })
    assert_equal "error: no address plat@athena; 'keryx who' lists the addresses on athena\n", none.err
  end

  def test_a_team_sender_names_its_own_team_by_a_bare_name_and_a_flat_address_in_full
    rev = join_claude('rev-1.dev', 222)
    unheld('orq')
    bare = keryx('send', 'orq', 'hello', env: rev)
    full = keryx('send', 'orq@athena', 'hello', env: rev)

    assert_equal "error: no address orq.dev@athena; 'keryx who' lists the addresses on athena\n", bare.err
    assert_equal [0, ''], [full.status, full.err]
  end

  # As the page of a person does: --as with the bare name from a process with no session and no USER.
  def test_a_page_acts_as_a_flat_address_by_its_bare_name_with_no_session_and_no_user
    unheld('hvpaiva')
    rev = join_claude('rev-1.dev', 222)
    keryx('ask', 'hvpaiva@athena', 'Approve the plan?', env: rev)
    page = ->(*argv, input: '') { keryx('--as', 'hvpaiva', *argv, env: { 'USER' => nil }, input:) }
    whoami, inbox, status, who = [%w[whoami], %w[inbox --all], %w[status], %w[who]].map do |argv|
      JSON.parse(page.call(*argv, '-o', 'json').out)
    end
    id = inbox.first['id']

    assert_equal ['hvpaiva@athena', [['Approve the plan?', 'hvpaiva@athena']]],
                 [whoami['address'], inbox.map { it.values_at('body', 'to') }]
    assert_equal([id], status['open_requests'].select { it['to'] == 'hvpaiva@athena' }.map { it['id'] })
    assert_includes who['addresses'].map { it['address'] }, 'hvpaiva@athena'
    assert_equal 'Approve the plan?', JSON.parse(page.call('read', id, '-o', 'json').out)['body']
  end

  def test_a_page_answers_and_writes_as_a_flat_address_with_its_text_on_standard_input
    unheld('hvpaiva')
    rev = join_claude('rev-1.dev', 222)
    keryx('ask', 'hvpaiva@athena', 'Approve the plan?', env: rev)
    id = JSON.parse(keryx('inbox', '-o', 'json', '--as', 'hvpaiva').out).first['id']
    page = ->(*argv, text) { keryx(*argv, '--file', '-', env: { 'USER' => nil }, input: text) }
    sent = [page.call('--as', 'hvpaiva', 'reply', id, 'Approved'),
            page.call('--as', 'hvpaiva', 'send', 'rev-1.dev@athena', 'FYI'),
            page.call('--as', 'hvpaiva@athena', 'ask', 'rev-1', '--within', '30m', 'Status?')]

    assert_equal([[0, true]] * 3, sent.map { [it.status, it.out.match?(/\b[0-9A-HJKMNP-TV-Z]{26}\b/)] })
    assert_equal([%w[hvpaiva@athena message], %w[hvpaiva@athena reply], %w[hvpaiva@athena request]],
                 store.mailbox('rev-1.dev').map { [it.message.from, it.message.kind] }.sort)
  end

  def test_completion_lists_flat_addresses_beside_team_ones
    orq = held('orq', 111)
    join_claude('rev-1.dev', 222)

    assert_equal %w[orq rev-1.dev], complete_words('send', '', env: orq)
    assert_equal %w[orq rev-1.dev], complete_words('--as', '')
  end

  def complete_words(*words, env: {}) = keryx('__complete', *words, env:).out.lines(chomp: true)
end
