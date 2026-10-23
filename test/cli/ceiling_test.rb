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
    FileUtils.cp(File.join(FIXTURES, 'claude-transcript.jsonl'), path)
  end

  def join_with_ceiling(name, pid, ceiling)
    alive << pid
    keryx('join', name, '--ceiling', ceiling, env: claude(pid))
  end

  def director(name) = store.occupant(name).director

  def test_join_keeps_the_ceiling_with_the_session_and_says_so
    result = join_with_ceiling('impl', 300, '125k')

    assert_equal "Joined impl@athena as a claude session (pid 300). Its context ceiling is 125k.\n", result.out
    assert_equal 125_000, store.occupant('impl').ceiling
    join_with_ceiling('impl', 300, '1.5M')

    assert_equal 1_500_000, store.occupant('impl').ceiling
  end

  def test_a_ceiling_that_is_not_a_token_count_is_a_usage_error
    alive << 300
    %w[12x 0 -5 1.5.5 k].each do |ceiling|
      result = keryx('join', 'impl', '--ceiling', ceiling, env: claude(300))

      assert_equal 2, result.status, ceiling
      assert_match(/invalid token count "#{Regexp.escape(ceiling)}": a number with an optional k or m/, result.err)
    end
    refute store.address?('impl')
  end

  def test_a_refresh_keeps_the_ceiling_and_the_director_and_a_new_join_starts_without_them
    join_with_ceiling('impl', 300, '125k')
    store.bind('impl', store.occupant('impl').with(director: 'orq'))
    keryx('whoami', env: claude(300).merge('CLAUDE_CODE_MESSAGING_SOCKET' => '/tmp/cc-300-new.sock'))

    assert_equal [125_000, 'orq', '/tmp/cc-300-new.sock'],
                 store.occupant('impl').to_h.values_at(:ceiling, :director, :claude_socket)
    keryx('join', 'impl', env: claude(300))

    assert_equal [nil, nil], store.occupant('impl').to_h.values_at(:ceiling, :director)
  end

  def test_spawn_passes_the_ceiling_in_the_join_line_of_the_first_prompt
    session_joins
    spawn('impl', '--harness', 'codex', '--role', 'implementer', '--ceiling', '125k')

    assert_includes herdr.starts.first[:arguments].last,
                    "Run 'keryx join impl --role implementer --ceiling 125k', then run 'keryx skill'"
  end

  def test_spawn_refuses_a_bad_ceiling_before_it_starts_anything
    result = spawn('impl', '--harness', 'codex', '--ceiling', 'lots', 'Implement retries')

    assert_equal 2, result.status
    assert_empty herdr.starts
    refute store.address?('impl')
  end

  def test_spawn_records_the_address_it_runs_as_as_the_director
    session_joins
    spawn('rev-1', '--harness', 'claude', 'Review PR #448')

    assert_equal 'person', director('rev-1')
    orq = join_claude('orq', 111)
    session_joins(pid: 501)
    spawn('rev-2', '--harness', 'claude', env: orq)

    assert_equal 'orq', director('rev-2')
    session_joins(pid: 502)
    spawn('rev-3', '--harness', 'claude', env: { 'KERYX_AS' => 'orq' })

    assert_equal 'orq', director('rev-3')
  end

  def test_a_spawn_with_no_address_to_run_as_records_no_director
    session_joins
    spawn('rev-1', '--harness', 'claude')

    assert_nil director('rev-1')
    refute store.address?('person')
  end

  def test_who_shows_the_context_against_the_ceiling_coloured_by_its_share
    claude_transcript(300)
    join_with_ceiling('impl', 300, '125k')
    claude_transcript(301)
    join_with_ceiling('docs', 301, '1m')
    claude_transcript(302)
    join_with_ceiling('rev-1', 302, '120k')
    output = keryx('--color', 'who').out

    assert_includes output, "\e[33m121k 97% of 125k\e[0m"
    assert_includes output, "\e[31m121k 101% of 120k\e[0m"
    assert_match(/^docs@athena\s+-\s+claude\s+live\s+121k 12% of 1M\s/, keryx('who').out)
    record = JSON.parse(keryx('who', '-o', 'json').out).find { it['address'] == 'impl@athena' }

    assert_equal [{ 'used' => 121_203, 'window' => nil }, 125_000], record.values_at('context', 'ceiling')
  end
end
