# frozen_string_literal: true

require 'test_helper'

class PresenceTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  SOCKET = '/h.sock'

  def codex_in(pane, thread) = { 'CODEX_THREAD_ID' => thread, 'HERDR_SOCKET_PATH' => SOCKET, 'HERDR_PANE_ID' => pane }

  def show(pane, kind, status, session = nil)
    herdr.put(SOCKET, pane, Keryx::Herdr::Agent.new(pane:, kind:, status:, session:))
  end

  # The harness runs as the foreground group of its pane, and keryx runs under it.
  def runs_in(pane, pid)
    herdr.foregrounds[[SOCKET, pane]] = pid
    lineage.replace([pid + 1, pid])
    alive << pid
  end

  def test_join_records_the_process_that_runs_in_the_foreground_of_its_pane
    runs_in('w1:p3', 500)
    keryx('join', 'impl', env: codex_in('w1:p3', 'thread-1'))
    herdr.foregrounds[[SOCKET, 'w1:p4']] = 700
    keryx('join', 'docs', env: codex_in('w1:p4', 'thread-2'))
    join_claude('rev-1', 111)

    assert_equal([500, 'started 500'], store.occupant('impl').then { [it.pid, it.started] })
    assert_nil store.occupant('docs').pid
    assert_equal 'started 111', store.occupant('rev-1').started
  end

  def test_a_new_session_in_the_pane_records_its_own_process
    runs_in('w1:p3', 500)
    keryx('join', 'impl', env: codex_in('w1:p3', 'thread-1'))
    keryx('inbox', env: codex_in('w1:p3', 'thread-1'))

    assert_equal 500, store.occupant('impl').pid
    runs_in('w1:p3', 900)
    keryx('inbox', env: codex_in('w1:p3', 'thread-2'))

    assert_equal(['thread-2', 900], store.occupant('impl').then { [it.session_id, it.pid] })
  end

  def test_a_session_id_herdr_reports_is_compared_even_when_the_session_has_none_of_its_own
    runs_in('w1:p3', 500)
    show('w1:p3', 'codex', 'idle', 'old-thread')
    keryx('join', 'impl', env: { 'HERDR_SOCKET_PATH' => SOCKET, 'HERDR_PANE_ID' => 'w1:p3' })

    assert_equal 'old-thread', store.occupant('impl').session_id
    show('w1:p3', 'codex', 'idle', 'new-thread')

    assert_match(/\(pane w1:p3 runs thread new-thread, not old-thread\)/, keryx('send', 'impl', 'hello').out)
    store.bind('impl', store.occupant('impl').with(session_id: nil))

    assert_match(/\(pane w1:p3 runs thread new-thread, and the session that joined recorded no thread\)/,
                 keryx('send', 'impl', 'hello again').out)
    assert_empty herdr.prompts
  end

  def test_a_lookup_that_does_not_answer_keeps_the_recorded_process
    runs_in('w1:p3', 500)
    env = codex_in('w1:p3', 'thread-1')
    keryx('join', 'impl', env:)
    show('w1:p3', 'codex', 'idle')
    processes.starts[500] = nil
    keryx('inbox', env:)
    processes.starts.delete(500)
    lineage.clear
    keryx('inbox', env:)
    lineage.replace([501, 500])

    assert_equal([500, 'started 500'], store.occupant('impl').then { [it.pid, it.started] })
    assert_match(/The bell rang through herdr\./, keryx('send', 'impl', 'hello').out)
  end

  def test_a_claude_session_that_reuses_the_pid_records_its_own_start
    env = join_claude('rev-1', 111)
    processes.starts[111] = nil
    keryx('inbox', env:)

    assert_equal 'started 111', store.occupant('rev-1').started
    processes.starts[111] = 'started later'
    keryx('inbox', env: env.merge('CLAUDE_CODE_SESSION_ID' => 'session-new',
                                  'CLAUDE_CODE_MESSAGING_SOCKET' => '/tmp/cc-new.sock'))

    assert_equal(['session-new', 'started later'], store.occupant('rev-1').then { [it.session_id, it.started] })
    assert_equal 1, keryx('leave', '--as', 'rev-1').status
  end

  # The one test that reads a real start, of this test's own process.
  def test_a_session_keeps_its_address_when_the_time_zone_changes
    @processes = Keryx::Processes.new
    zone = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'UTC'
    join_claude('rev-1', Process.pid)
    ENV['TZ'] = 'America/Sao_Paulo'

    assert_equal 1, keryx('leave', '--as', 'rev-1').status
    assert_equal Process.pid, store.occupant('rev-1').pid
  ensure
    ENV['TZ'] = zone
  end

  def test_a_spawned_codex_whose_hooks_are_not_trusted_is_typed_into_while_its_process_runs
    runs_in('w1:p3', 500)
    keryx('join', 'impl', env: codex_in('w1:p3', 'thread-1'))
    show('w1:p3', 'codex', 'idle')

    assert_match(/The bell rang through herdr\./, keryx('send', 'impl', 'hello').out)
    runs_in('w1:p3', 900)

    assert_match(/The bell did not reach the session that holds impl@athena \(pane w1:p3 runs process 900, not 500\)/,
                 keryx('send', 'impl', 'still there?').out)
    assert_empty codex.queued
  end

  def test_leave_as_keeps_a_session_whose_activity_herdr_cannot_tell
    alive << 111
    keryx('join', 'rev-1', env: claude(111).merge('HERDR_SOCKET_PATH' => SOCKET, 'HERDR_PANE_ID' => 'w1:p2'))
    show('w1:p2', 'claude', 'unknown', 'session-111')
    keryx('join', 'impl', env: codex_in('w1:p3', 'thread-1'))
    show('w1:p3', 'codex', 'unknown', 'thread-1')
    keryx('join', 'docs', env: codex_in('w1:p4', 'thread-2'))
    herdr.unanswered << [SOCKET, 'w1:p4']

    statuses = %w[rev-1 impl docs].map { keryx('leave', '--as', it).status }
    kept = [store.occupant('rev-1').pid, *%w[impl docs].map { store.occupant(it).session_id }]

    assert_equal [1, 1, 1], statuses
    assert_equal [111, 'thread-1', 'thread-2'], kept
    assert_equal 'live', JSON.parse(keryx('who', '-o', 'json').out).find { it['address'] == 'rev-1@athena' }['session']
  end

  def test_the_reply_note_promises_no_bell_the_bell_would_not_ring
    outside = { 'CODEX_THREAD_ID' => 'thread-1' }
    keryx('join', 'reviewer', env: outside)
    join_claude('worker', 111)
    keryx('join', 'stale', env: codex_in('w1:p2', 'old-thread'))
    show('w1:p2', 'codex', 'idle', 'new-thread')
    notes = [keryx('ask', 'worker', 'Review this', '--as', 'reviewer', env: outside),
             keryx('ask', 'worker', 'Review that', '--as', 'stale')].map { it.out.lines.last }

    assert_equal(['keryx cannot reach the session that holds reviewer@athena, so no bell rings for the reply;',
                  'keryx cannot reach the session that holds stale@athena, so no bell rings for the reply;'],
                 notes.map { it[/\A[^;]+;/] })
  end
end
