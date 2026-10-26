# frozen_string_literal: true

require 'test_helper'

# who shows the director the courier tells about a dialog, in its table and its JSON. Adapted from
# director_contract_probe.rb, rev-54's probe in its review of pull request #42.
class WhoDirectorTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  SOCKET = '/h.sock'
  PANE = 'w1:p2'

  def member(director)
    join_claude('impl.dev', 222)
    store.bind('impl.dev', store.occupant('impl.dev').with(director:, herdr_socket: SOCKET, herdr_pane: PANE))
    herdr.put(SOCKET, PANE, Keryx::Herdr::Agent.new(pane: PANE, kind: 'claude', status: 'blocked'))
    herdr.views[[SOCKET, PANE]] = Screens.real('claude-write')
  end

  def displaced_orq
    former = join_claude('orq.dev', 111)
    session = store.occupant('orq.dev').session
    alive << 333
    result = keryx('join', 'orq.dev', '--force', env: claude(333))
    raise "join --force failed: #{result.err}" unless result.status.zero?

    [former, session]
  end

  # The director in who's JSON and table, and each address the courier then tells about the dialog.
  def directors
    json = JSON.parse(keryx('who', '--all', '-o', 'json').out)['addresses'].find { it['address'] == 'impl.dev@athena' }
    row = keryx('who', '--all').out.lines.map(&:split).find { it.first == 'impl.dev@athena' }
    round = keryx('courier', '--once')
    raise "the courier failed: #{round.err}" unless round.status.zero?

    told = store.all_messages.map { it.last.message }.select { it.body.include?(' stops at a dialog ') }.map(&:to)
    [json['director'], row[2], told]
  end

  def test_a_stable_director_is_shown_and_told_there
    join_claude('orq.dev', 111)
    member('orq.dev')

    assert_equal ['orq.dev@athena', 'orq.dev@athena', ['orq.dev@athena']], directors
  end

  def test_a_displaced_director_whose_session_runs_is_shown_and_told_at_its_session_address
    _, session = displaced_orq
    member("orq.dev/#{session}")
    address = "orq.dev@athena/#{session}"

    assert_equal [address, address, [address]], directors
  end

  def test_a_displaced_director_whose_session_left_is_shown_and_told_at_the_address_it_held
    former, session = displaced_orq
    member("orq.dev/#{session}")

    assert_equal 0, keryx('leave', env: former).status
    assert_equal ['orq.dev@athena', 'orq.dev@athena', ['orq.dev@athena']], directors
  end

  def test_a_director_whose_session_ended_is_shown_and_told_at_the_address_it_held
    join_claude('orq.dev', 111)
    member("orq.dev/#{store.occupant('orq.dev').session}")
    alive.delete(111)

    assert_equal ['orq.dev@athena', 'orq.dev@athena', ['orq.dev@athena']], directors
  end

  def test_a_director_whose_session_is_not_the_one_holding_its_address_is_shown_and_told_at_that_address
    join_claude('orq.dev', 111)
    member('orq.dev/abcdef')

    assert_equal ['orq.dev@athena', 'orq.dev@athena', ['orq.dev@athena']], directors
  end

  def test_a_director_retired_here_is_none_and_told_nothing
    join_claude('orq.dev', 111)
    member("orq.dev/#{store.occupant('orq.dev').session}")
    store.retire('orq.dev', by: 'person.local', now: NOW)

    assert_equal [nil, '-', []], directors
  end
end
