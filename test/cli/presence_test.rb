# frozen_string_literal: true

require 'test_helper'

class PresenceTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include PresenceHelpers

  def test_join_records_the_process_that_runs_in_the_foreground_of_its_pane
    runs_in('w1:p3', 500)
    keryx('join', 'impl.dev', env: codex_in('w1:p3', 'thread-1'))
    herdr.foregrounds[[SOCKET, 'w1:p4']] = 700
    keryx('join', 'docs.dev', env: codex_in('w1:p4', 'thread-2'))
    join_claude('rev-1.dev', 111)

    assert_equal([500, 'started 500'], store.occupant('impl.dev').then { [it.pid, it.started] })
    assert_nil store.occupant('docs.dev').pid
    assert_equal 'started 111', store.occupant('rev-1.dev').started
  end

  def test_a_new_session_in_the_pane_records_its_own_process
    runs_in('w1:p3', 500)
    keryx('join', 'impl.dev', env: codex_in('w1:p3', 'thread-1'))
    keryx('inbox', env: codex_in('w1:p3', 'thread-1'))

    assert_equal 500, store.occupant('impl.dev').pid
    runs_in('w1:p3', 900)
    keryx('inbox', env: codex_in('w1:p3', 'thread-2'))

    assert_equal(['thread-2', 900], store.occupant('impl.dev').then { [it.session_id, it.pid] })
  end

  def test_a_session_id_herdr_reports_is_compared_even_when_the_session_has_none_of_its_own
    runs_in('w1:p3', 500)
    show('w1:p3', 'codex', 'idle', 'old-thread')
    keryx('join', 'impl.dev', env: { 'HERDR_SOCKET_PATH' => SOCKET, 'HERDR_PANE_ID' => 'w1:p3' })

    assert_equal 'old-thread', store.occupant('impl.dev').session_id
    show('w1:p3', 'codex', 'idle', 'new-thread')

    assert_match(/\(pane w1:p3 runs thread new-thread, not old-thread\)/, keryx('send', 'impl.dev', 'hello').out)
    store.bind('impl.dev', store.occupant('impl.dev').with(session_id: nil))

    assert_match(/\(pane w1:p3 runs thread new-thread, and the session that joined recorded no thread\)/,
                 keryx('send', 'impl.dev', 'hello again').out)
    assert_empty herdr.prompts
  end

  def test_a_lookup_that_does_not_answer_keeps_the_recorded_process
    runs_in('w1:p3', 500)
    env = codex_in('w1:p3', 'thread-1')
    keryx('join', 'impl.dev', env:)
    show('w1:p3', 'codex', 'idle')
    processes.starts[500] = nil
    keryx('inbox', env:)
    processes.starts.delete(500)
    lineage.clear
    keryx('inbox', env:)
    lineage.replace([501, 500])

    assert_equal([500, 'started 500'], store.occupant('impl.dev').then { [it.pid, it.started] })
    assert_match(/The bell rang through herdr\./, keryx('send', 'impl.dev', 'hello').out)
  end

  def test_a_claude_session_that_reuses_the_pid_records_its_own_start
    env = join_claude('rev-1.dev', 111)
    processes.starts[111] = nil
    keryx('inbox', env:)

    assert_equal 'started 111', store.occupant('rev-1.dev').started
    processes.starts[111] = 'started later'
    keryx('inbox', env: env.merge('CLAUDE_CODE_SESSION_ID' => 'session-new',
                                  'CLAUDE_CODE_MESSAGING_SOCKET' => '/tmp/cc-new.sock'))

    assert_equal(['session-new', 'started later'], store.occupant('rev-1.dev').then { [it.session_id, it.started] })
    assert_equal 1, keryx('leave', '--as', 'rev-1.dev').status
  end

  # The one test that reads a real start, of this test's own process.
  def test_a_session_keeps_its_address_when_the_time_zone_changes
    @processes = Keryx::Processes.new
    zone = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'UTC'
    join_claude('rev-1.dev', Process.pid)
    ENV['TZ'] = 'America/Sao_Paulo'

    assert_equal 1, keryx('leave', '--as', 'rev-1.dev').status
    assert_equal Process.pid, store.occupant('rev-1.dev').pid
  ensure
    ENV['TZ'] = zone
  end

  def test_a_spawned_codex_whose_hooks_are_not_trusted_is_typed_into_while_its_process_runs
    runs_in('w1:p3', 500)
    keryx('join', 'impl.dev', env: codex_in('w1:p3', 'thread-1'))
    show('w1:p3', 'codex', 'idle')

    assert_match(/The bell rang through herdr\./, keryx('send', 'impl.dev', 'hello').out)
    runs_in('w1:p3', 900)

    assert_match(/bell did not reach the session that holds impl.dev@athena \(pane w1:p3 runs process 900, not 500\)/,
                 keryx('send', 'impl.dev', 'still there?').out)
    assert_empty codex.queued
  end

  def test_leave_as_keeps_a_session_whose_activity_herdr_cannot_tell
    alive << 111
    keryx('join', 'rev-1.dev', env: claude(111).merge('HERDR_SOCKET_PATH' => SOCKET, 'HERDR_PANE_ID' => 'w1:p2'))
    show('w1:p2', 'claude', 'unknown', 'session-111')
    keryx('join', 'impl.dev', env: codex_in('w1:p3', 'thread-1'))
    show('w1:p3', 'codex', 'unknown', 'thread-1')
    keryx('join', 'docs.dev', env: codex_in('w1:p4', 'thread-2'))
    herdr.unanswered << [SOCKET, 'w1:p4']

    statuses = %w[rev-1.dev impl.dev docs.dev].map { keryx('leave', '--as', it).status }
    kept = [store.occupant('rev-1.dev').pid, *%w[impl.dev docs.dev].map { store.occupant(it).session_id }]

    assert_equal [1, 1, 1], statuses
    assert_equal [111, 'thread-1', 'thread-2'], kept
    assert_equal 'live', session('rev-1.dev')
  end

  def test_the_reply_note_promises_no_bell_the_bell_would_not_ring
    outside = { 'CODEX_THREAD_ID' => 'thread-1' }
    keryx('join', 'reviewer.dev', env: outside)
    join_claude('worker.dev', 111)
    keryx('join', 'stale.dev', env: codex_in('w1:p2', 'old-thread'))
    show('w1:p2', 'codex', 'idle', 'new-thread')
    notes = [keryx('ask', 'worker.dev', 'Review this', '--as', 'reviewer.dev', env: outside),
             keryx('ask', 'worker.dev', 'Review that', '--as', 'stale.dev')].map { it.out.lines.last }

    assert_equal(['keryx cannot reach the session that holds reviewer.dev@athena, so no bell rings for the reply;',
                  'keryx cannot reach the session that holds stale.dev@athena, so no bell rings for the reply;'],
                 notes.map { it[/\A[^;]+;/] })
  end

  def test_a_session_herdr_relaunched_in_its_pane_keeps_its_address
    relaunched_claude('rev-1.dev', 111)
    alive << 222
    refusals = [keryx('leave', '--as', 'rev-1.dev'), keryx('retire', 'rev-1.dev'),
                keryx('join', 'rev-1.dev', env: claude(222))]

    assert_equal 'working', session('rev-1.dev')
    assert_equal [1, 1, 1], refusals.map(&:status)
    assert_match(/rev-1\.dev@athena is held by another live claude session \(pid 111, pane w1:p2\)/, refusals[0].err)
    assert_equal 'session-111', store.occupant('rev-1.dev').session_id
    assert_equal 0, keryx('send', "rev-1.dev/#{store.occupant('rev-1.dev').session}", 'still there?').status
  end

  def test_join_force_displaces_a_relaunched_session_to_its_session_address
    relaunched_claude('rev-1.dev', 111)
    keryx('join', 'rev-1.dev', '--force', env: claude(222).tap { alive << 222 })
    displaced = store.outgoing('rev-1.dev').map { store.occupant("rev-1.dev/#{it}").session_id }

    assert_equal ['session-111'], displaced
    assert_equal 'session-222', store.occupant('rev-1.dev').session_id
  end

  def test_a_relaunched_session_whose_pane_holds_nothing_or_another_session_is_gone
    relaunched_claude('rev-1.dev', 111)
    relaunched_claude('impl.dev', 333, pane: 'w1:p3')
    herdr.put(SOCKET, 'w1:p2', nil)
    show('w1:p3', 'claude', 'idle', 'session-444')

    assert_equal %w[gone gone], [session('rev-1.dev'), session('impl.dev')]
    assert_equal [0, 0], [keryx('leave', '--as', 'rev-1.dev'), keryx('retire', 'impl.dev')].map(&:status)
    assert_nil store.occupant('rev-1.dev')
    assert store.retired?('impl.dev')
  end

  private

  # herdr relaunched the session with --resume: the same session in the same pane, under a process that is not the one
  # that joined.
  def relaunched_claude(name, pid, pane: 'w1:p2')
    alive << pid
    keryx('join', name, env: claude(pid).merge('HERDR_SOCKET_PATH' => SOCKET, 'HERDR_PANE_ID' => pane))
    alive.delete(pid)
    show(pane, 'claude', 'working', "session-#{pid}")
  end
end
