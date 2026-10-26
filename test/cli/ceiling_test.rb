# frozen_string_literal: true

require 'test_helper'

class CeilingTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers

  FIXTURES = File.expand_path('../fixtures/context', __dir__)

  def claude_transcript(pid)
    path = tmp('home', '.claude', 'projects', '-work', "session-#{pid}.jsonl")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, File.read(File.join(FIXTURES, 'claude-transcript.jsonl')).gsub('"session-1"', %("session-#{pid}")))
  end

  def join_with_ceiling(name, pid, ceiling)
    alive << pid
    keryx('join', name, '--ceiling', ceiling, env: claude(pid))
  end

  def director(name) = store.occupant(name).director

  def test_join_keeps_the_ceiling_with_the_session_and_says_so
    result = join_with_ceiling('impl.dev', 300, '125k')

    assert_equal "Joined impl.dev@athena as a claude session (pid 300). Its context ceiling is 125k.\n", result.out
    assert_equal 125_000, store.occupant('impl.dev').ceiling
    join_with_ceiling('impl.dev', 300, '1.5M')

    assert_equal 1_500_000, store.occupant('impl.dev').ceiling
  end

  def test_a_ceiling_that_is_not_a_token_count_is_a_usage_error
    alive << 300
    %w[12x 0 -5 1.5.5 k].each do |ceiling|
      result = keryx('join', 'impl.dev', '--ceiling', ceiling, env: claude(300))

      assert_equal 2, result.status, ceiling
      assert_match(/invalid token count "#{Regexp.escape(ceiling)}": a number with an optional k or m/, result.err)
    end
    refute store.address?('impl.dev')
  end

  def test_a_refresh_keeps_the_ceiling_and_the_director_and_a_new_join_starts_without_them
    join_with_ceiling('impl.dev', 300, '125k')
    store.bind('impl.dev', store.occupant('impl.dev').with(director: 'orq.dev'))
    keryx('whoami', env: claude(300).merge('CLAUDE_CODE_MESSAGING_SOCKET' => '/tmp/cc-300-new.sock'))

    assert_equal [125_000, 'orq.dev', '/tmp/cc-300-new.sock'],
                 store.occupant('impl.dev').to_h.values_at(:ceiling, :director, :claude_socket)
    keryx('join', 'impl.dev', env: claude(300))

    assert_equal [nil, nil], store.occupant('impl.dev').to_h.values_at(:ceiling, :director)
  end

  def test_spawn_passes_the_ceiling_in_the_join_line_of_the_first_prompt
    session_joins
    spawn('impl.dev', '--harness', 'codex', '--role', 'implementer', '--ceiling', '125k')

    assert_includes herdr.starts.first[:arguments].last,
                    "Run 'keryx join impl.dev --role implementer --ceiling 125k', then run 'keryx skill'"
  end

  def test_spawn_refuses_a_bad_ceiling_before_it_starts_anything
    result = spawn('impl.dev', '--harness', 'codex', '--ceiling', 'lots', 'Implement retries')

    assert_equal 2, result.status
    assert_empty herdr.starts
    refute store.address?('impl.dev')
  end

  def test_spawn_records_the_address_it_runs_as_as_the_director
    session_joins
    spawn('rev-1.dev', '--harness', 'claude', 'Review PR #448')

    assert_equal 'person.local', director('rev-1.dev')
    orq = join_claude('orq.dev', 111)
    session_joins(pid: 501)
    spawn('rev-2.dev', '--harness', 'claude', env: orq)

    assert_equal 'orq.dev', director('rev-2.dev')
    session_joins(pid: 502)
    spawn('rev-3', '--harness', 'claude', env: { 'KERYX_AS' => 'orq.dev' })

    assert_equal 'orq.dev', director('rev-3.dev')
  end

  def test_a_spawn_with_no_address_to_run_as_records_no_director
    session_joins
    spawn('rev-1.dev', '--harness', 'claude')

    assert_nil director('rev-1.dev')
    refute store.address?('person.local')
  end

  def gave_up_spawn(*argv, env: {})
    session_runs
    result = spawn('impl.dev', '--harness', 'claude', '--timeout', '1s', *argv, env:)

    assert_equal 3, result.status
    herdr.starts.last
  end

  def join_from(pane, session, *argv) = keryx('join', 'impl.dev', *argv, env: session.merge(in_pane(SOCKET, pane)))

  def test_a_session_that_joins_after_spawn_gave_up_takes_its_director_and_ceiling
    started = gave_up_spawn('--ceiling', '125k', env: join_claude('orq.dev', 111))
    join_line = started[:arguments].last[/Run '([^']+)'/, 1]
    alive << 500
    keryx(*Shellwords.split(join_line).drop(1), env: claude(500).merge(in_pane(SOCKET, started[:pane])))

    assert_equal ['orq.dev', 125_000], store.occupant('impl.dev').to_h.values_at(:director, :ceiling)
  end

  def test_only_the_session_spawn_started_takes_the_director_and_only_on_the_first_join
    pane = gave_up_spawn(env: join_claude('orq.dev', 111))[:pane]
    join_from(pane, { 'CODEX_THREAD_ID' => 'thread-600' })

    assert_nil director('impl.dev')
    alive << 500
    join_from(pane, claude(500), '--force')

    assert_nil director('impl.dev')
  end

  def test_a_spawn_with_no_address_to_run_as_clears_what_an_earlier_spawn_recorded
    pane = gave_up_spawn(env: join_claude('orq.dev', 111))[:pane]
    gave_up_spawn
    alive << 500
    join_from(pane, claude(500))

    assert_nil director('impl.dev')
  end

  def test_who_shows_the_context_against_the_ceiling_coloured_by_its_share
    claude_transcript(300)
    join_with_ceiling('impl.dev', 300, '125k')
    claude_transcript(301)
    join_with_ceiling('docs.dev', 301, '1m')
    claude_transcript(302)
    join_with_ceiling('rev-1.dev', 302, '120k')
    output = keryx('--color', 'who').out

    assert_includes output, "\e[33m121k 97% of 125k\e[0m"
    assert_includes output, "\e[31m121k 101% of 120k\e[0m"
    assert_match(/^docs.dev@athena\s+-\s+-\s+claude\s+live\s+\S+ ago\s+121k 12% of 1M\s/, keryx('who').out)
    record = JSON.parse(keryx('who', '-o', 'json').out)['addresses'].find { it['address'] == 'impl.dev@athena' }

    assert_equal [{ 'used' => 121_203, 'window' => nil }, 125_000], record.values_at('context', 'ceiling')
  end

  def test_the_courier_tells_the_session_and_its_director_once_and_says_so
    claude_transcript(300)
    join_with_ceiling('impl.dev', 300, '125k')
    join_claude('orq.dev', 111)
    store.bind('impl.dev', store.occupant('impl.dev').with(director: 'orq.dev'))
    output = keryx('courier', '--once').out
    notice = JSON.parse(keryx('inbox', '-o', 'json', env: claude(111)).out).last

    assert_equal "told impl.dev@athena that impl.dev@athena is at 121k 97% of 125k, near its context ceiling\n" \
                 "told orq.dev@athena that impl.dev@athena is at 121k 97% of 125k, near its context ceiling\n", output
    assert_equal ['keryx.system@athena', nil], notice.values_at('from', 'context')
    assert_empty keryx('courier', '--once').out
  end

  def test_a_damaged_claim_of_the_notice_near_the_ceiling_is_shown_and_holds_no_ceiling_notice_back
    claude_transcript(300)
    join_with_ceiling('impl.dev', 300, '125k')
    keryx('courier', '--once')
    claim = Dir[tmp('state', 'addresses', 'impl.dev', 'receipts', '*.context-id')].first
    File.write(claim, 'not-json')
    transcript = tmp('home', '.claude', 'projects', '-work', 'session-300.jsonl')
    read = '"cache_read_input_tokens":'
    File.write(transcript, File.read(transcript).sub("#{read}120000", "#{read}130000"))
    runs = [keryx('courier', '--once'), keryx('status')]

    assert_equal "told impl.dev@athena that impl.dev@athena is at 131k 105% of 125k, its context ceiling\n" \
                 'the ceiling notice of impl.dev@athena to impl.dev@athena takes a fresh id and may sort before the ' \
                 "notice near it; #{claim} is damaged\n", runs.first.out
    assert_equal([[0, 1]] * 2, runs.map { [it.status, it.err.scan("warning: #{claim} is damaged").size] })
  end
end
