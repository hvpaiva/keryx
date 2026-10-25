# frozen_string_literal: true

require 'test_helper'

class JoinRaceTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include ProcessRaces

  def test_two_joins_of_one_session_at_once_leave_it_one_address
    session = { 'CODEX_THREAD_ID' => 'shared-thread' }
    statuses = finish(release_when_settled(start('alpha', 'join', 'alpha.dev', env: session),
                                           start('beta.dev', 'join', 'beta.dev', env: session)))

    assert_equal [0, 0], statuses.values
    assert_equal 1, held.size, "held: #{held.inspect}"
    assert_equal "#{held.first}@athena", JSON.parse(keryx('whoami', '-o', 'json', env: session).out)['address']
    keryx('leave', env: session)

    assert_match(/holds no address/, keryx('whoami', env: session).err)
  end

  def test_two_sessions_that_join_one_free_address_at_once_get_one_join
    sessions = { 'first' => claude(Process.pid), 'second' => claude(Process.ppid) }
    statuses = finish(release_when_settled(*sessions.map { |label, env| start(label, 'join', 'solo.dev', env:) }))
    winner, loser = statuses.keys.sort_by { statuses[it] }

    assert_equal [0, 1], statuses.values_at(winner, loser)
    assert_match(/solo.dev@athena is held by another live claude session/, File.read(tmp("pause-#{loser}.err")))
    assert_equal sessions.fetch(winner)['CLAUDE_CODE_SESSION_ID'], store.occupant('solo.dev').session_id
  end

  def test_a_command_that_records_the_session_again_during_a_join_leaves_one_address
    keryx('join', 'alpha.dev', env: claude(111))
    restarted = claude(111).merge('CLAUDE_PID' => '222')
    inbox = start('inbox', 'inbox', env: restarted, pause: 'refresh')
    wait_until('inbox to read the occupant it records again') { File.exist?(tmp('pause-inbox.ready')) }
    joined = keryx('join', 'beta.dev', env: restarted)
    File.write(tmp('release'), '')

    assert_equal [0, 0], [joined.status, finish([inbox]).fetch('inbox')]
    assert_equal ['beta.dev'], held
  end

  def test_a_leave_while_the_session_is_recorded_again_stays_done
    keryx('join', 'alpha.dev', env: claude(111))
    restarted = claude(111).merge('CLAUDE_PID' => '222')
    inbox = stopped(start('inbox', 'inbox', env: restarted))
    statuses = finish(release_when_ended_or_waiting(inbox, start('leave', 'leave', env: restarted, pause: 'none')))

    assert_equal({ 'inbox' => 0, 'leave' => 0 }, statuses)
    assert_empty held
  end

  def test_a_late_leave_spares_the_session_that_took_the_address_over
    keryx('join', 'alpha.dev', env: { 'CODEX_THREAD_ID' => 'first' })
    leave = stopped(start('leave', 'leave', env: { 'CODEX_THREAD_ID' => 'first' }, pause: 'unbind'))
    join = start('join', 'join', 'alpha.dev', '--force', env: { 'CODEX_THREAD_ID' => 'second' }, pause: 'none')
    statuses = finish(release_when_ended_or_waiting(leave, join))

    assert_equal({ 'leave' => 0, 'join' => 0 }, statuses)
    assert_equal 'second', store.occupant('alpha.dev')&.session_id
  end
end
