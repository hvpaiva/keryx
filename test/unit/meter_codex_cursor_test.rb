# frozen_string_literal: true

require 'test_helper'

class MeterCodexCursorTest < Minitest::Test
  include TempDir
  include Factory
  include MeterHelpers

  def test_codex_takes_the_last_token_count_event_with_its_window
    rollout

    assert_equal Keryx::Context.new(used: 137_000, window: 258_400),
                 read(harness: 'codex', session_id: 'thread-1')
    assert_equal '137k/258k 53%', read(harness: 'codex', session_id: 'thread-1').label
  end

  def test_codex_takes_the_last_count_and_passes_over_an_event_without_one
    rollout([meta, *[{ 'input_tokens' => 64_000 }, { 'input_tokens' => '1' }, {}, nil].map { token_count(it) }]
              .join("\n"))

    assert_equal Keryx::Context.new(used: 64_000, window: nil), read(harness: 'codex', session_id: 'thread-1')
  end

  def test_codex_stops_at_a_last_count_of_zero_rather_than_report_an_older_one
    rollout([meta, *[{ 'input_tokens' => 64_000 }, { 'input_tokens' => 0 }, { 'input_tokens' => '1' }]
              .map { token_count(it) }].join("\n"))

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

  def test_codex_reads_a_rollout_only_when_it_opens_with_the_thread_and_through_no_link
    rollout(fixture('codex-rollout.jsonl').sub('"id":"thread-1"', '"id":"thread-2"'))

    assert_nil read(harness: 'codex', session_id: 'thread-1')
    FileUtils.rm_rf(tmp('home', '.codex'))
    other = put(tmp('outside', 'rollout-2026-10-22T17-00-00-thread-1.jsonl'), fixture('codex-rollout.jsonl'))
    link(other, tmp('home', '.codex', 'sessions', '2026', '10', '22', File.basename(other)))

    assert_nil read(harness: 'codex', session_id: 'thread-1')
    FileUtils.rm_rf(tmp('home', '.codex'))
    link(File.dirname(other), tmp('home', '.codex', 'sessions', '2026', '10', '22'))

    assert_nil read(harness: 'codex', session_id: 'thread-1')
  end

  def test_codex_lists_the_rollouts_once_for_each_meter
    rollout
    once = meter

    assert_equal 137_000, once.read(build_occupant(harness: 'codex', session_id: 'thread-1')).used
    rollout(fixture('codex-rollout.jsonl').gsub('thread-1', 'thread-2'), thread: 'thread-2', day: '2026/10/23')

    assert_nil once.read(build_occupant(harness: 'codex', session_id: 'thread-2'))
    assert_equal 137_000, read(harness: 'codex', session_id: 'thread-2').used
  end

  def test_a_count_no_window_could_hold_is_no_figure
    rollout([meta, token_count('input_tokens' => 1_000_000_001)].join("\n"))
    transcript(assistant('input_tokens' => 1_000_000_001))

    assert_nil read(harness: 'codex', session_id: 'thread-1')
    assert_nil read
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

  def test_cursor_reads_the_share_when_labels_such_as_the_files_edited_follow_it
    screen = Screens.unescaped(fixture('cursor-file-edited.txt'))
    without = screen.sub(" #{DOT} 1 file edited", '')

    refute_equal screen, without
    assert_equal Keryx::Context.new(used: 161_024, window: 256_000), cursor(screen)
    assert_equal '161k/256k 63%', cursor(screen).label
    assert_equal cursor(screen), cursor(without)
    assert_equal cursor(screen), cursor(screen.sub('1 file edited', '12 files edited'))
  end

  def test_cursor_takes_the_footer_and_never_the_directory_or_the_input_line
    assert_equal Keryx::Context.new(used: 243_600, window: 300_000),
                 cursor("Claude Opus 5.5 300K Extra High #{DOT} 81.2%\n  /work/report 1M #{DOT} 99%\n")
    assert_equal Keryx::Context.new(used: 243_600, window: 300_000),
                 cursor("Claude Opus 5.5 300K Extra High #{DOT} 81.2%\n  report 1M #{DOT} 99%\n")
    assert_nil cursor("> Document this budget 300K #{DOT} 99%\n\nClaude Opus 5.5 300K Extra High\n  /work\n")
    assert_nil cursor("Claude Opus 5.5 300K Extra High   Run Everything\n  report 1M #{DOT} 99%\n")
  end

  def test_cursor_reads_only_its_last_lines_and_only_the_footer_shape
    assert_nil cursor("Model 300K High #{DOT} 81%\n#{"text\n" * 4}")
    ["Model 300KB #{DOT} 81%", "Model 300K #{DOT} 81% left", "Model 300K #{DOT} 81%x", 'Model 300K - 81%',
     "Model 4.7K #{DOT} 9%", "Model 300K #{DOT} 81% #{DOT}", '', nil].each { assert_nil cursor(it), it.inspect }
  end

  def test_cursor_reads_nothing_unless_its_pane_runs_that_session
    %i[elsewhere unproven unanswered].each do |verdict|
      assert_nil cursor("Claude Opus 5.5 300K Extra High #{DOT} 81.2%", verdict:)
    end
  end

  def test_cursor_gives_no_figure_when_another_conversation_takes_the_pane_while_its_footer_is_read
    seen = pane_reading_its_footer

    assert_equal 243_600, seen.call.used
    herdr.define_singleton_method(:footer) do |socket, pane|
      put(socket, pane, Keryx::Herdr::Agent.new(pane:, kind: 'cursor', status: 'idle', session: 'conversation-2'))
      footers[[socket, pane]]
    end

    assert_nil seen.call
  end

  def test_cursor_gives_no_figure_when_herdr_does_not_answer_the_look_after_its_footer
    seen = pane_reading_its_footer
    herdr.define_singleton_method(:footer) do |socket, pane|
      unanswered << [socket, pane]
      footers[[socket, pane]]
    end

    assert_nil seen.call
  end

  def test_a_reader_that_fails_gives_no_figure
    herdr.define_singleton_method(:footer) { |*| raise Keryx::Error, 'herdr is gone' }

    assert_nil cursor('ignored')
    assert_nil read(harness: 'other')
    assert_nil meter.read(nil)
  end

  private

  def pane_reading_its_footer
    @lookout = Keryx::Lookout.new(herdr:, processes: CLIHelpers::FakeProcesses.new([]))
    herdr.put(SOCKET, 'w1:p2', Keryx::Herdr::Agent.new(pane: 'w1:p2', kind: 'cursor', status: 'idle',
                                                       session: 'conversation-1'))
    herdr.footers[[SOCKET, 'w1:p2']] = "Claude Opus 5.5 300K Extra High #{DOT} 81.2%"
    -> { read(harness: 'cursor', session_id: 'conversation-1', herdr_socket: SOCKET, herdr_pane: 'w1:p2') }
  end
end
