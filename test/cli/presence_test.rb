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

  # A Codex started by hand in a herdr pane keeps herdr's variables, and drops them from the commands it runs.
  def codex_by_hand(pane, pid, holder: pid, secret: 's3cret')
    runs_in(pane, pid)
    processes.environments[holder] = { 'HERDR_SOCKET_PATH' => SOCKET, 'HERDR_PANE_ID' => pane, 'TOKEN' => secret }
    show(pane, 'codex', 'idle')
    { 'CODEX_THREAD_ID' => 'thread-1' }
  end

  def session(name) = JSON.parse(keryx('who', '-o', 'json').out).find { it['address'] == "#{name}@athena" }['session']

  def test_a_codex_started_by_hand_in_a_pane_is_placed_by_the_variables_it_kept
    env = codex_by_hand('w1:p3', 500)
    joined = keryx('join', 'impl', env:)

    assert_equal "Joined impl@athena as a codex session (pid 500, thread thread-1, pane w1:p3).\n", joined.out
    assert_equal([SOCKET, 'w1:p3', 500], store.occupant('impl').then { [it.herdr_socket, it.herdr_pane, it.pid] })
    assert_equal 'idle', session('impl')
    assert_match(/The bell rang through herdr\./, keryx('send', 'impl', 'hello').out)
    refute_includes File.read(tmp('state', 'addresses', 'impl', 'occupant.json')), 's3cret'
  end

  def test_the_pane_an_older_join_recorded_gets_its_process_from_the_next_command
    env = codex_by_hand('w1:p3', 500, holder: 499)
    lineage.replace([501, 500, 499])
    store.create_address('impl')
    store.bind('impl', build_occupant(harness: 'codex', session_id: 'thread-1', herdr_socket: SOCKET,
                                      herdr_pane: 'w1:p3'))
    keryx('whoami', env:)

    assert_equal([SOCKET, 'w1:p3', 500], store.occupant('impl').then { [it.herdr_socket, it.herdr_pane, it.pid] })
    assert_match(/The bell rang through herdr\./, keryx('send', 'impl', 'hello').out)
  end

  def test_a_command_that_proves_no_pane_keeps_the_one_recorded
    store.create_address('impl')
    recorded = build_occupant(harness: 'codex', session_id: 'thread-1', herdr_socket: SOCKET, herdr_pane: 'w1:p3')
    store.bind('impl', recorded)
    keryx('whoami', env: { 'CODEX_THREAD_ID' => 'thread-1' })

    assert_equal recorded, store.occupant('impl')
  end

  UNPROVEN = {
    'another pane runs in the foreground' => ->(test) { test.herdr.foregrounds[[SOCKET, 'w1:p3']] = 900 },
    'a server under the pane carries its variables' => lambda { |test|
      test.lineage.replace([501, 600, 500])
      test.processes.environments[600] = test.processes.environments.delete(500)
    },
    'a process the command does not run under has them' => lambda { |test|
      test.processes.environments[700] = test.processes.environments.delete(500)
    }
  }.freeze

  def test_variables_a_session_cannot_prove_it_runs_under_place_nothing
    UNPROVEN.each do |label, change|
      FileUtils.rm_rf(tmp('state'))
      env = codex_by_hand('w1:p3', 500)
      change.call(self)
      keryx('join', 'impl', env:)
      occupant = store.occupant('impl')

      assert_equal [nil, nil, 'unknown'], [occupant.herdr_pane, occupant.pid, session('impl')], label
    end
  end

  def joined_before_the_upgrade(**overrides)
    show('w1:p3', 'codex', 'idle')
    store.create_address('impl')
    store.bind('impl', build_occupant(harness: 'codex', session_id: 'thread-1', herdr_socket: SOCKET,
                                      herdr_pane: 'w1:p3', **overrides))
  end

  def test_every_note_says_how_a_session_that_joined_before_the_upgrade_is_rung_again
    joined_before_the_upgrade
    orq = join_claude('orq', 111)
    request = build_message(to: 'orq@athena', from: 'impl@athena', kind: 'request').tap { store.deliver('orq', it) }
    notes = [keryx('send', 'impl', 'hello', env: orq).out, keryx('ask', 'impl', 'Review it', env: orq).out,
             keryx('reply', request.id, 'Done', env: orq).out, keryx('status').out, keryx('courier', '--once').out]
    reason = 'the session that joined pane w1:p3 recorded no process, as one that joined under an older keryx; ' \
             'a keryx command it runs from that pane, such as keryx whoami, records it'

    assert_equal([1, 1, 1, 3, 1], notes.map { it.scan(reason).size }, 'status lists the three messages not rung')
  end

  def test_a_session_whose_process_keryx_can_check_is_never_told_to_run_whoami
    runs_in('w1:p3', 500)
    { 'a pid without its start' => { pid: 500 }, 'another process' => { pid: 600, started: 'started 600' },
      'a restarted process' => { pid: 500, started: 'started before' } }.each do |label, recorded|
      joined_before_the_upgrade(**recorded)
      note = keryx('send', 'impl', 'hello').out

      assert_match(/\(nothing shows that pane|\(pane w1:p3 runs process|\(process 500 in pane/, note, label)
      refute_match(/older keryx|whoami/, note, label)
    end
    show('w1:p3', 'codex', 'idle', 'thread-2')

    refute_match(/older keryx|whoami/, keryx('send', 'impl', 'hello').out)
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
