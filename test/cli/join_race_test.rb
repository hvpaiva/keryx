# frozen_string_literal: true

require 'test_helper'

class JoinRaceTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include ProcessRaces

  def test_two_joins_of_one_session_at_once_leave_it_one_address
    session = { 'CODEX_THREAD_ID' => 'shared-thread' }
    statuses = finish(release_when_settled(start('alpha', 'join', 'alpha', env: session),
                                           start('beta', 'join', 'beta', env: session)))

    assert_equal [0, 0], statuses.values
    assert_equal 1, held.size, "held: #{held.inspect}"
    assert_equal "#{held.first}@athena", JSON.parse(keryx('whoami', '-o', 'json', env: session).out)['address']
    keryx('leave', env: session)

    assert_match(/holds no address/, keryx('whoami', env: session).err)
  end

  def test_two_sessions_that_join_one_free_address_at_once_get_one_join
    sessions = { 'first' => claude(Process.pid), 'second' => claude(Process.ppid) }
    statuses = finish(release_when_settled(*sessions.map { |label, env| start(label, 'join', 'solo', env:) }))
    winner, loser = statuses.keys.sort_by { statuses[it] }

    assert_equal [0, 1], statuses.values_at(winner, loser)
    assert_match(/solo@athena is held by another live claude session/, File.read(tmp("pause-#{loser}.err")))
    assert_equal sessions.fetch(winner)['CLAUDE_CODE_SESSION_ID'], store.occupant('solo').session_id
  end

  def test_a_command_that_records_the_session_again_during_a_join_leaves_one_address
    keryx('join', 'alpha', env: claude(111))
    restarted = claude(111).merge('CLAUDE_PID' => '222')
    inbox = start('inbox', 'inbox', env: restarted, pause: 'refresh')
    wait_until('inbox to read the occupant it records again') { File.exist?(tmp('pause-inbox.ready')) }
    joined = keryx('join', 'beta', env: restarted)
    File.write(tmp('release'), '')

    assert_equal [0, 0], [joined.status, finish([inbox]).fetch('inbox')]
    assert_equal ['beta'], held
  end
end
