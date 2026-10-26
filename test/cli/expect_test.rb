# frozen_string_literal: true

require 'test_helper'

class ExpectTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers

  RECORD = { 'director' => 'orq.dev', 'harness' => 'claude', 'herdr_socket' => SOCKET, 'herdr_pane' => 'w1:p3' }.freeze
  RECORDED = 'Expecting rev-1.dev@athena as a claude session in pane w1:p3; it takes orq.dev@athena for its director ' \
             "when it joins.\n"

  def setup
    super
    workspace(%w[w1:t1 main] => { 'w1:p1' => AREA, 'w1:p3' => AREA, 'w1:p4' => AREA })
  end

  # The launcher's orchestrator, a Claude session in pane w1:p1.
  def orq = @orq ||= join_claude('orq.dev', 111).merge(CALLER)

  def expecting(*argv, env: orq) = keryx('expect', 'rev-1.dev', '--harness', 'claude', '--pane', 'w1:p3', *argv, env:)

  def file = tmp('state', 'addresses', 'rev-1.dev', 'spawned.json')

  def waiting = JSON.parse(File.read(file))

  def entry
    JSON.parse(keryx('who', '--all', '-o', 'json').out)['addresses'].find { it['address'] == 'rev-1.dev@athena' }
  end

  def stamp = File.stat(file).then { [it.ino, it.mtime] }

  # The session the launcher starts in pane w1:p3 joins the address.
  def seat_joins(*argv, pid: 500, pane: 'w1:p3', session: claude(pid), socket: SOCKET)
    alive << pid
    keryx('join', 'rev-1.dev', *argv, env: session.merge(in_pane(socket, pane)))
  end

  def test_the_session_in_the_pane_takes_the_director_and_its_join_gives_the_role
    result = expecting

    assert_equal [0, RECORDED], [result.status, result.out], result.err
    assert_nil store.address('rev-1.dev').role
    assert_equal RECORD.merge('director' => 'orq.dev@athena'), entry['spawned']
    assert_equal 0, seat_joins('--role', 'reviewer').status
    assert_equal ['orq.dev@athena', 'reviewer', nil], entry.values_at('director', 'role', 'spawned')
  end

  def test_a_session_of_another_pane_or_harness_takes_no_director_and_its_join_removes_the_record
    [['w1:p4', claude(500)], ['w1:p3', { 'CODEX_THREAD_ID' => 'thread-500' }]].each do |pane, session|
      expected = expecting

      assert_equal [0, RECORD], [expected.status, waiting], expected.err
      seat_joins(pane:, session:)

      assert_equal [nil, nil], entry.values_at('director', 'spawned'), pane
      keryx('leave', env: session.merge(in_pane(SOCKET, pane)))
    end
  end

  def test_the_director_is_the_address_this_command_acts_as
    join_claude('lead.dev', 222)
    store.create_address('ana.local', role: 'human')
    directors = [[%w[--as lead.dev], orq], [[], CALLER], [%w[--as ana.local], CALLER]].map do |argv, env|
      expecting(*argv, '--replace', env:).then { [it.status, waiting['director']] }
    end

    assert_equal [[0, 'lead.dev'], [0, 'person.local'], [0, 'ana.local']], directors
    assert_equal 'human', store.address('person.local').role
  end

  def test_the_reserved_scopes_are_refused_as_the_director_and_as_the_address
    as_person = expecting('--as', 'person.local')
    unjoined = expecting(env: claude(333).merge(CALLER))
    targets = %w[person.local keryx.system].product([orq, CALLER]).map do |target, env|
      keryx('expect', target, '--harness', 'claude', '--pane', 'w1:p3', env:)
    end

    assert_match(/an agent session cannot act as person\.local@athena/, as_person.err)
    assert_match(/this claude session holds no address/, unjoined.err)
    assert_equal([[1, true]] * 4, targets.map { [it.status, it.err.include?('is in a reserved scope')] })
    assert_equal 2, keryx('expect', 'rev-1.dev/k3m9qz', '--harness', 'claude', '--pane', 'w1:p3', env: orq).status
    assert_equal [1, 1], [as_person.status, unjoined.status]
    refute_path_exists file
  end

  # herdr gives the pane its socket as it was given, so the record and the join compare one lexical form.
  def test_a_socket_spelled_another_way_is_recorded_plainly_and_its_session_takes_the_director
    %w[/./h.sock //h.sock /x/../h.sock].each.with_index(500) do |socket, pid|
      recorded = expecting('--socket', socket)

      assert_equal [0, SOCKET], [recorded.status, waiting['herdr_socket']], recorded.err
      assert_equal [0, 'orq.dev@athena'], [seat_joins(pid:).status, entry['director']], socket
      assert_equal 'joined', JSON.parse(expecting('--socket', socket, '-o', 'json').out)['outcome'], socket
      keryx('leave', env: claude(pid).merge(in_pane(SOCKET, 'w1:p3')))
    end
    expecting
    seat_joins(pid: 600, socket: '//h.sock')

    assert_equal 'orq.dev@athena', entry['director']
  end

  def test_a_retired_address_and_one_a_live_session_holds_are_refused
    holder = join_claude('rev-1.dev', 222)
    held = expecting
    keryx('leave', env: holder)
    keryx('retire', 'rev-1.dev', env: orq)
    retired = expecting

    assert_equal [1, 1], [held.status, retired.status]
    assert_match(/rev-1\.dev@athena is held by another live claude session \(pid 222\); choose another name/, held.err)
    assert_match(/rev-1\.dev@athena is retired; bring it back with 'keryx join rev-1\.dev --revive'/, retired.err)
    refute_path_exists file
  end

  def test_the_same_run_again_changes_nothing
    expecting
    written = stamp
    again = expecting
    json = JSON.parse(expecting('-o', 'json').out)

    assert_equal 0, again.status
    assert_equal "rev-1.dev@athena already expects a claude session in pane w1:p3, directed by orq.dev@athena.\n",
                 again.out
    assert_equal 'unchanged', json['outcome']
    assert_equal written, stamp
  end

  def test_a_different_record_is_refused_and_left_until_replaced
    join_claude('lead.dev', 222)
    changes = [['--harness', 'codex', 'harness', 'codex'], ['--pane', 'w1:p4', 'herdr_pane', 'w1:p4'],
               ['--socket', '/other.sock', 'herdr_socket', '/other.sock'], ['--as', 'lead.dev', 'director', 'lead.dev']]
    changes.each do |option, value, field, recorded|
      expecting('--replace')
      refused = expecting(option, value)

      assert_equal [1, RECORD], [refused.status, waiting], option
      assert_includes refused.err, 'rev-1.dev@athena already expects a claude session in pane w1:p3 of /h.sock, ' \
                                   'directed by orq.dev@athena; pass --replace to expect this one instead'
      replaced = JSON.parse(expecting(option, value, '--replace', '-o', 'json').out)

      assert_equal ['replaced', recorded], [replaced['outcome'], waiting[field]], option
    end
  end

  def test_a_replaced_record_is_named
    expecting
    replaced = expecting('--pane', 'w1:p4', '--replace')

    assert_equal 0, replaced.status
    assert_equal "#{RECORDED.sub('w1:p3', 'w1:p4')}It replaces the record of a claude session in pane w1:p3 of " \
                 "/h.sock, directed by orq.dev@athena.\n", replaced.out
  end

  def test_after_the_session_joined_the_same_run_succeeds_and_another_is_held
    expecting
    seat_joins
    joined = expecting
    json = JSON.parse(expecting('-o', 'json').out)
    join_claude('lead.dev', 222)
    others = [expecting('--pane', 'w1:p4'), expecting('--as', 'lead.dev')]

    assert_equal 0, joined.status
    assert_equal "rev-1.dev@athena already joined as the claude session in pane w1:p3, directed by orq.dev@athena.\n",
                 joined.out
    assert_equal 'joined', json['outcome']
    assert_equal([[1, true]] * 2, others.map { [it.status, it.err.include?('is held by another live claude session')] })
    refute_path_exists file
  end

  def test_what_cannot_be_recorded_is_a_usage_error
    runs = [keryx('expect', 'rev-1.dev', '--pane', 'w1:p3', env: orq),
            keryx('expect', 'rev-1.dev', '--harness', 'claude', env: orq),
            expecting('--pane=-h'), expecting('--pane', 'w1 p3'), expecting('--pane', "w#{'1' * 64}"),
            expecting('--socket', 'h.sock'),
            keryx('expect', 'rev-1.dev', '--harness', 'claude', '--pane', 'w1:p3', env: claude(111))]

    assert_equal [2] * 7, runs.map(&:status)
    assert_equal(['missing --harness', 'missing --pane', *['invalid pane'] * 3, 'invalid socket', 'missing --socket'],
                 runs.map { it.err[/\Aerror: (\S+ [^\s:]+)/, 1] })
    refute_path_exists file
  end

  def test_a_pane_herdr_does_not_know_is_refused
    result = expecting('--pane', 'w9:p9')

    assert_equal 1, result.status
    assert_match(/herdr pane get failed: no pane w9:p9/, result.err)
    refute_path_exists file
  end

  def test_json_gives_the_address_the_outcome_and_the_record_with_the_full_director
    json = JSON.parse(expecting('-o', 'json').out)

    assert_equal RECORD.merge('address' => 'rev-1.dev@athena', 'outcome' => 'recorded',
                              'director' => 'orq.dev@athena'), json.except('schema')
  end

  def test_help_lists_the_options_of_expect_apart_from_the_global_ones
    help = keryx('expect', '--help').out

    assert_match(/^Usage:\n  keryx expect \[options\] ADDRESS$/, help)
    assert_match(/^Options:\n {6}--harness HARNESS .*\n {6}--pane PANE .*\n {6}--socket PATH .*\n {6}--replace .*\n/,
                 help)
  end

  def test_a_spawn_of_the_address_replaces_what_expect_recorded
    expected = expecting
    session_runs

    assert_equal [0, RECORD], [expected.status, waiting], expected.err

    assert_equal 3, spawn('rev-1.dev', '--harness', 'codex', '--timeout', '5s', env: orq).status
    assert_equal %w[orq.dev codex], waiting.values_at('director', 'harness')
    refute_equal 'w1:p3', waiting['herdr_pane']
  end
end
