# frozen_string_literal: true

require 'test_helper'

# A session that keeps no herdr variables in its commands, and the records that say how keryx can tell it apart.
class PaneProofTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include PresenceHelpers

  UNPROVEN = {
    'another pane runs in the foreground' => ->(test) { test.herdr.foregrounds[[SOCKET, 'w1:p3']] = 900 },
    'a server under the pane carries its variables' => lambda { |test|
      test.lineage.replace([501, 600, 500])
      test.processes.environments[600] = test.processes.environments.delete(500)
    },
    'a process the command does not run under has them' => lambda { |test|
      test.processes.environments[700] = test.processes.environments.delete(500)
    },
    'another Codex started this one without them' => lambda { |test|
      test.lineage.replace([601, 600, 501, 500])
      test.carry_thread('thread-1', 601)
      test.carry_thread('outer-thread', 600, 501)
    },
    'the command does not carry its thread' => ->(test) { test.processes.environments.delete(Process.pid) }
  }.freeze

  def test_a_codex_started_by_hand_in_a_pane_is_placed_by_the_variables_it_kept
    env = codex_by_hand('w1:p3', 500)
    joined = keryx('join', 'impl.dev', env:)

    assert_equal "Joined impl.dev@athena as a codex session (pid 500, thread thread-1, pane w1:p3).\n", joined.out
    assert_equal([SOCKET, 'w1:p3', 500], store.occupant('impl.dev').then { [it.herdr_socket, it.herdr_pane, it.pid] })
    assert_equal 'idle', session('impl.dev')
    assert_match(/The bell rang through herdr\./, keryx('send', 'impl.dev', 'hello').out)
    refute_includes File.read(tmp('state', 'addresses', 'impl.dev', 'occupant.json')), 's3cret'
  end

  def test_the_pane_an_older_join_recorded_gets_its_process_from_the_next_command
    env = codex_by_hand('w1:p3', 500)
    bind_impl(older: true)
    keryx('whoami', env:)

    assert_equal([SOCKET, 'w1:p3', 500], store.occupant('impl.dev').then { [it.herdr_socket, it.herdr_pane, it.pid] })
    assert_match(/The bell rang through herdr\./, keryx('send', 'impl.dev', 'hello').out)
  end

  def test_a_command_that_proves_no_pane_keeps_the_one_recorded
    recorded = bind_impl
    keryx('whoami', env: { 'CODEX_THREAD_ID' => 'thread-1' })

    assert_equal recorded, store.occupant('impl.dev')
  end

  def test_variables_a_session_cannot_prove_it_runs_under_place_nothing
    UNPROVEN.each do |label, change|
      FileUtils.rm_rf(tmp('state'))
      env = codex_by_hand('w1:p3', 500)
      change.call(self)
      keryx('join', 'impl.dev', env:)
      occupant = store.occupant('impl.dev')

      assert_equal [nil, nil, 'unknown'], [occupant.herdr_pane, occupant.pid, session('impl.dev')], label
    end
  end

  def test_a_codex_started_from_another_never_gets_the_bells_of_the_outer_one
    runs_in('w1:p3', 500)
    show('w1:p3', 'codex', 'idle')
    keryx('join', 'outer.dev', env: codex_in('w1:p3', 'outer-thread'))
    processes.environments[500] = { 'HERDR_SOCKET_PATH' => SOCKET, 'HERDR_PANE_ID' => 'w1:p3' }
    lineage.replace([601, 600, 501, 500])
    carry_thread('inner-thread', Process.pid, 601)
    carry_thread('outer-thread', 600, 501)
    keryx('join', 'inner.dev', env: { 'CODEX_THREAD_ID' => 'inner-thread' })

    assert_match(/\(thread inner-thread has no herdr pane\)/, keryx('send', 'inner.dev', 'For the inner one').out)
    assert_empty herdr.prompts
    assert_equal([500, 'w1:p3'], store.occupant('outer.dev').then { [it.pid, it.herdr_pane] })
  end

  def test_every_note_says_how_a_session_that_joined_before_processes_were_kept_is_rung_again
    show('w1:p3', 'codex', 'idle')
    bind_impl(older: true)
    orq = join_claude('orq.dev', 111)
    request = build_message(to: 'orq.dev@athena', from: 'impl.dev@athena', kind: 'request')
    store.deliver('orq.dev', request)
    notes = [keryx('send', 'impl.dev', 'hello', env: orq).out, keryx('ask', 'impl.dev', 'Review it', env: orq).out,
             keryx('reply', request.id, 'Done', env: orq).out, keryx('status').out, keryx('courier', '--once').out]
    reason = 'the session that joined pane w1:p3 recorded no process to tell it by; a keryx command run in that ' \
             'session, such as keryx whoami, can record it'

    assert_equal([1, 1, 1, 3, 1], notes.map { it.scan(reason).size }, 'status lists the three messages not rung')
  end

  def test_a_join_that_recorded_no_process_is_not_told_a_command_will
    show('w1:p3', 'codex', 'idle')
    herdr.foregrounds[[SOCKET, 'w1:p3']] = 500
    lineage.replace([601, 600])
    env = codex_in('w1:p3', 'thread-1')
    keryx('join', 'impl.dev', env:)
    2.times { keryx('whoami', env:) }
    note = keryx('send', 'impl.dev', 'hello').out

    assert_nil store.occupant('impl.dev').pid
    assert_includes note, '(the session that joined pane w1:p3 recorded no process to tell it by)'
    refute_match(/older keryx|whoami/, note)
  end

  def test_an_older_record_a_command_could_not_complete_stops_offering_whoami
    show('w1:p3', 'codex', 'idle')
    bind_impl(older: true)
    keryx('whoami', env: { 'CODEX_THREAD_ID' => 'thread-1' })

    refute_match(/whoami/, keryx('send', 'impl.dev', 'hello').out)
  end

  def test_a_session_whose_process_keryx_can_check_is_never_told_to_run_whoami
    runs_in('w1:p3', 500)
    show('w1:p3', 'codex', 'idle')
    { 'a pid without its start' => { pid: 500 }, 'another process' => { pid: 600, started: 'started 600' },
      'a restarted process' => { pid: 500, started: 'started before' } }.each do |label, recorded|
      bind_impl(older: label == 'a pid without its start', **recorded)
      note = keryx('send', 'impl.dev', 'hello').out

      assert_match(/\(nothing shows that pane|\(pane w1:p3 runs process|\(process 500 in pane/, note, label)
      refute_match(/older keryx|whoami/, note, label)
    end
    show('w1:p3', 'codex', 'idle', 'thread-2')

    refute_match(/older keryx|whoami/, keryx('send', 'impl.dev', 'hello').out)
  end
end
