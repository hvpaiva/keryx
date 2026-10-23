# frozen_string_literal: true

require 'test_helper'

class MeterTest < Minitest::Test
  include TempDir
  include Factory

  SOCKET = '/h.sock'
  FIXTURES = File.expand_path('../fixtures/context', __dir__)
  DOT = [0xB7].pack('U')
  ARROW = [0x2192].pack('U')
  SLUG = '-work-repo-v1-0'

  class Lookout
    attr_accessor :verdict

    def initialize = @verdict = :there

    def in_pane(_occupant) = Keryx::Lookout::Sighting.new(verdict:, agent: nil, detail: nil)
  end

  def herdr = @herdr ||= FakeHerdr.new

  def lookout = @lookout ||= Lookout.new

  def env = @env ||= { 'HOME' => tmp('home') }

  def meter = Keryx::Meter.new(env:, herdr:, lookout:)

  def read(**occupant) = meter.read(build_occupant(cwd: '/work/repo.v1_0', **occupant))

  def fixture(name) = File.read(File.join(FIXTURES, name))

  def put(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def transcript(content = fixture('claude-transcript.jsonl'), slug: SLUG, id: 'session-1', home: nil)
    put(File.join(home || tmp('home', '.claude'), 'projects', slug, "#{id}.jsonl"), content)
  end

  def rollout(content = fixture('codex-rollout.jsonl'), day: '2026/10/22', thread: 'thread-1', home: nil)
    put(File.join(home || tmp('home', '.codex'), 'sessions', day, "rollout-2026-10-22T17-00-00-#{thread}.jsonl"),
        content)
  end

  def assistant(usage)
    JSON.generate('type' => 'assistant', 'isSidechain' => false,
                  'message' => { 'role' => 'assistant', 'content' => [], 'usage' => usage })
  end

  def cursor(footer, verdict: :there)
    lookout.verdict = verdict
    herdr.footers[[SOCKET, 'w1:p2']] = footer
    read(harness: 'cursor', session_id: 'conversation-1', herdr_socket: SOCKET, herdr_pane: 'w1:p2')
  end

  def test_claude_counts_the_last_main_turn_with_its_cache_from_the_folder_of_its_directory
    transcript

    assert_equal Keryx::Context.new(used: 121_203, window: nil), read
    assert_equal '121k', read.label
  end

  def test_claude_reads_the_transcript_the_hook_recorded_before_any_derived_one
    transcript
    recorded = put(tmp('kept', 'projects', 'x', 'session-1.jsonl'), assistant('input_tokens' => 42_000))

    assert_equal 42_000, read(transcript: recorded).used
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

  def test_codex_takes_the_last_token_count_event_with_its_window
    rollout

    assert_equal Keryx::Context.new(used: 137_000, window: 258_400),
                 read(harness: 'codex', session_id: 'thread-1')
    assert_equal '137k/258k 53%', read(harness: 'codex', session_id: 'thread-1').label
  end

  def token_count(usage)
    JSON.generate('type' => 'event_msg', 'payload' => { 'type' => 'token_count',
                                                        'info' => { 'last_token_usage' => usage,
                                                                    'model_context_window' => 'big' } })
  end

  def test_codex_takes_the_last_count_and_passes_over_an_event_without_one
    rollout([{ 'input_tokens' => 64_000 }, { 'input_tokens' => '1' }, {}, nil].map { token_count(it) }.join("\n"))

    assert_equal Keryx::Context.new(used: 64_000, window: nil), read(harness: 'codex', session_id: 'thread-1')
  end

  def test_codex_stops_at_a_last_count_of_zero_rather_than_report_an_older_one
    rollout([{ 'input_tokens' => 64_000 }, { 'input_tokens' => 0 }, { 'input_tokens' => '1' }]
              .map { token_count(it) }.join("\n"))

    assert_nil read(harness: 'codex', session_id: 'thread-1')
  end

  def test_codex_reads_only_its_own_single_rollout_under_its_home
    rollout(thread: 'thread-2')

    assert_nil read(harness: 'codex', session_id: 'thread-1')
    rollout
    rollout(day: '2026/10/23')

    assert_nil read(harness: 'codex', session_id: 'thread-1')
    env['CODEX_HOME'] = tmp('codex')
    rollout(home: tmp('codex'))

    assert_equal 137_000, read(harness: 'codex', session_id: 'thread-1').used
  end

  def test_cursor_reads_the_window_and_share_from_its_footer_above_the_directory
    screen = ["  #{ARROW} Add a follow-up", '', '',
              "  Grok 4.7 256K Extra High #{DOT} MAX #{DOT} 7.8%#{' ' * 40}Run Everything -- INSERT --",
              '  /home/u/work/a-directory-long-eno', '  ugh-to-wrap'].join("\n")

    assert_equal Keryx::Context.new(used: 19_968, window: 256_000), cursor("#{screen}\n")
    assert_equal '20k/256k 8%', cursor(screen).label
    assert_equal Keryx::Context.new(used: 243_600, window: 300_000),
                 cursor("Claude Opus 5.5 300K Extra High #{DOT} 81.2%\n  /work\n\n")
    assert_equal 1_000_000, cursor("Claude Sonnet 1M #{DOT} 5%").window
  end

  def test_cursor_reads_only_its_last_lines_and_only_the_footer_shape
    assert_nil cursor("Model 300K High #{DOT} 81%\n#{"text\n" * 4}")
    ["Model 300KB #{DOT} 81%", "Model 300K #{DOT} 81% left", "Model 300K #{DOT} 81%x", 'Model 300K - 81%',
     "Model 4.7K #{DOT} 9%", '', nil].each { assert_nil cursor(it), it.inspect }
  end

  def test_cursor_reads_nothing_unless_its_pane_runs_that_session
    %i[elsewhere unproven unanswered].each do |verdict|
      assert_nil cursor("Claude Opus 5.5 300K Extra High #{DOT} 81.2%", verdict:)
    end
  end

  def test_a_reader_that_fails_gives_no_figure
    herdr.define_singleton_method(:footer) { |*| raise Keryx::Error, 'herdr is gone' }

    assert_nil cursor('ignored')
    assert_nil read(harness: 'other')
    assert_nil meter.read(nil)
  end

  def test_a_transcript_a_hook_names_counts_only_where_claude_code_keeps_that_session
    kept = transcript

    assert_equal File.realpath(kept), Keryx::Meter.transcript(kept, 'session-1')
    outside = put(tmp('outside', 'session-1.jsonl'), '')
    linked = tmp('home', '.claude', 'projects', '-linked', 'session-1.jsonl')
    FileUtils.mkdir_p(File.dirname(linked))
    File.symlink(outside, linked)
    deeper = put(tmp('home', '.claude', 'projects', 'a', 'b', 'session-1.jsonl'), '')

    [[kept, 'session-2'], [outside, 'session-1'], [linked, 'session-1'], [deeper, 'session-1'],
     ['session-1.jsonl', 'session-1'], [kept, '../session-1'], [tmp('none', 'session-1.jsonl'), 'session-1'],
     [nil, 'session-1'], [kept, nil]].each { |path, id| assert_nil Keryx::Meter.transcript(path, id), path }
  end
end
