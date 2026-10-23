# frozen_string_literal: true

require 'test_helper'

class MeterTest < Minitest::Test
  include TempDir
  include Factory
  include MeterHelpers

  def test_claude_counts_the_last_main_turn_with_its_cache_from_the_folder_of_its_directory
    transcript

    assert_equal Keryx::Context.new(used: 121_203, window: nil), read
    assert_equal '121k', read.label
  end

  def test_claude_reads_the_transcript_the_hook_recorded_before_any_derived_one
    transcript
    recorded = put(tmp('home', '.claude', 'projects', 'x', 'session-1.jsonl'), assistant('input_tokens' => 42_000))

    assert_equal 42_000, read(transcript: recorded).used
  end

  def test_claude_counts_only_turns_of_its_own_session
    transcript([assistant({ 'input_tokens' => 7000 }), assistant({ 'input_tokens' => 99_000 }, 'session-2')]
                 .join("\n"))

    assert_equal 7000, read.used
  end

  def test_claude_follows_no_link_to_another_sessions_transcript
    other = put(tmp('outside', 'session-1.jsonl'), assistant('input_tokens' => 99_001))
    link(other, tmp('home', '.claude', 'projects', SLUG, 'session-1.jsonl'))

    assert_nil read
    FileUtils.rm_rf(tmp('home', '.claude', 'projects'))
    link(other, tmp('home', '.claude', 'projects', '-elsewhere', 'session-1.jsonl'))

    assert_nil read
    FileUtils.rm_rf(tmp('home', '.claude', 'projects'))
    put(tmp('outside', 'tree', 'session-1.jsonl'), assistant('input_tokens' => 99_002))
    link(tmp('outside', 'tree'), tmp('home', '.claude', 'projects', SLUG))

    assert_nil read
  end

  def test_claude_reads_a_recorded_transcript_only_in_its_own_projects_directory_unlinked
    transcript
    elsewhere = put(tmp('other', 'projects', 'x', 'session-1.jsonl'), assistant('input_tokens' => 99_003))
    linked = link(elsewhere, tmp('home', '.claude', 'projects', 'y', 'session-1.jsonl'))

    assert_equal [121_203, 121_203], [read(transcript: elsewhere).used, read(transcript: linked).used]
  end

  def test_claude_never_opens_a_recorded_transcript_of_another_session
    transcript
    other = put(tmp('kept', 'projects', 'x', 'session-2.jsonl'), assistant('input_tokens' => 999_999))
    loose = put(tmp('kept', 'session-1.jsonl'), assistant('input_tokens' => 999_999))

    assert_equal [121_203, 121_203], [read(transcript: other).used, read(transcript: loose).used]
  end

  def test_claude_honors_its_config_directory_even_relative_and_never_falls_back_to_the_home_one
    transcript
    env['CLAUDE_CONFIG_DIR'] = tmp('claude-config')

    assert_nil read
    transcript(assistant('input_tokens' => 5000), home: tmp('claude-config'))

    assert_equal 5000, read.used
    repo = tmp('repo')
    transcript(assistant('input_tokens' => 6000), slug: repo.gsub(/[^A-Za-z0-9]/, '-'), home: File.join(repo, 'cfg'))
    env['CLAUDE_CONFIG_DIR'] = 'cfg'

    assert_equal 6000, read(cwd: repo).used
  end

  def test_claude_finds_a_transcript_under_another_folder_only_when_it_is_the_one_match
    transcript(slug: '-elsewhere')

    assert_equal 121_203, read.used
    transcript(slug: '-another')

    assert_nil read
  end

  def test_claude_skips_usage_it_cannot_count_without_failing
    lines = [assistant('input_tokens' => 2000, 'cache_read_input_tokens' => 8000),
             assistant('input_tokens' => '9000'), assistant('input_tokens' => nil, 'cache_read_input_tokens' => -1),
             assistant([1, 2]), JSON.generate('type' => 'assistant', 'message' => 'usage'),
             JSON.generate('type' => 'assistant', 'message' => { 'usage' => 'none' }), assistant({}),
             '["usage"]', '{"type":"assistant","message":{"usage":{"input_tokens":7']
    transcript(lines.join("\n"))

    assert_equal 10_000, read.used
  end

  def test_claude_reads_a_line_longer_than_a_block_and_stops_eight_mebibytes_back
    long = assistant('input_tokens' => 300, 'cache_read_input_tokens' => 70_000, 'padding' => 'x' * 100_000)
    path = transcript("#{long}\n")

    assert_equal 70_300, read.used
    File.write(path, "#{assistant('input_tokens' => 1)}\n#{'{}' * (4 * 1024 * 1024)}\n")

    assert_nil read
  end

  def test_claude_needs_a_session_id_fit_for_a_file_name
    transcript(id: 'session-1')

    ['../session-1', '*', nil, 'a/b', ''].each { assert_nil read(session_id: it) }
  end

  def test_claude_never_waits_on_a_pipe
    path = tmp('home', '.claude', 'projects', SLUG, 'session-1.jsonl')
    FileUtils.mkdir_p(File.dirname(path))
    File.mkfifo(path)

    assert_nil read
    assert_nil read(transcript: path)
  end

  def test_a_transcript_a_hook_names_counts_only_where_claude_code_keeps_that_session
    kept = transcript

    assert_equal kept, Keryx::Meter.transcript(kept, 'session-1')
    outside = put(tmp('outside', 'session-1.jsonl'), '')
    linked = tmp('home', '.claude', 'projects', '-linked', 'session-1.jsonl')
    FileUtils.mkdir_p(File.dirname(linked))
    File.symlink(outside, linked)
    deeper = put(tmp('home', '.claude', 'projects', 'a', 'b', 'session-1.jsonl'), '')

    [[kept, 'session-2'], [outside, 'session-1'], [linked, 'session-1'], [deeper, 'session-1'],
     ['session-1.jsonl', 'session-1'], [kept, '../session-1'], [tmp('none', 'session-1.jsonl'), 'session-1'],
     [nil, 'session-1'], [kept, nil], ["#{kept}\0", 'session-1'], ["#{File.dirname(kept)}/../#{SLUG}/session-1.jsonl",
                                                                   'session-1']]
      .each { |path, id| assert_nil Keryx::Meter.transcript(path, id), path.inspect }
  end

  def test_the_occupants_transcript_lies_in_the_projects_directory_keryx_would_read
    kept = transcript
    elsewhere = put(tmp('other', 'projects', SLUG, 'session-1.jsonl'), '')
    occupant = build_occupant(cwd: '/work/repo.v1_0')

    assert_equal [kept, nil], [meter.transcript(kept, occupant), meter.transcript(elsewhere, occupant)]
    env['CLAUDE_CONFIG_DIR'] = tmp('other')

    assert_equal [nil, elsewhere], [meter.transcript(kept, occupant), meter.transcript(elsewhere, occupant)]
  end
end
