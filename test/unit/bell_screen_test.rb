# frozen_string_literal: true

require 'test_helper'

class BellScreenTest < Minitest::Test
  WORKING = Screens.session('codex-working-transcript')
  # The Codex capture above its composer: a tool's output that quotes the hooks screen and the folder trust.
  TRANSCRIPT = WORKING.lines.take_while { !it.start_with?("\u203a") }.join
  # Codex shows each prompt sent to it in its transcript, where it looks like its composer.
  PROMPTED = "#{TRANSCRIPT}\u203a Check the hooks screen again\n\n".freeze

  def obstacle(screen) = Keryx::Bell.obstacle(screen)

  def evidence(screen) = Keryx::Bell.reading(screen).evidence

  def test_a_codex_screen_whose_transcript_quotes_dialogs_above_its_composer_is_no_dialog
    assert_match(/Hooks need review/, TRANSCRIPT)
    assert_nil obstacle(WORKING)
  end

  def test_an_idle_screen_whose_last_answer_quotes_dialogs_above_its_composer_is_no_dialog
    quoted = '  The trust screen asks "Do you trust the contents of this directory?" with "[a] Trust this workspace".'
    cursor = Screens.session('cursor-idle').sub(/^  ok$/, quoted)

    assert_includes cursor, quoted
    assert_nil obstacle(Screens::CLAUDE_IDLE)
    assert_nil obstacle(cursor)
  end

  def test_a_dialog_in_place_of_the_composer_still_counts_under_that_transcript
    assert_equal :dialog, obstacle(TRANSCRIPT + Screens.captured.fetch('codex-120'))
    assert_equal :dialog, obstacle(PROMPTED + Screens.captured.fetch('codex-120'))
  end

  def test_a_captured_dialog_still_counts_under_a_transcript_that_quotes_dialogs
    Screens.captured.each do |name, screen|
      refute_nil obstacle(TRANSCRIPT + screen), name
      next unless obstacle(screen) == :dialog

      assert_equal :dialog, obstacle(PROMPTED + screen), name
    end
  end

  def test_the_selected_entry_of_a_menu_is_no_composer
    question = "  Do you trust the files in this folder?\n\n"

    assert_equal :dialog, obstacle("#{question}\u203a Trust\n  Quit\n")
    assert_equal :dialog, obstacle("#{question}  Trust\n\u203a Quit\n")
    assert_equal :dialog, obstacle("#{question}\u2192 Trust\n  Quit\n")
  end

  def test_only_the_lines_below_the_composer_count
    assert_equal :dialog, obstacle("\u203a Ask Codex to do anything\n\n  Hooks need review\n")
    assert_nil obstacle("  Hooks need review\n\n\u203a Ask Codex to do anything")
  end

  def test_cursor_s_follow_ups_box_is_no_dialog_with_or_without_its_composer
    box = Screens.session('cursor-follow-ups')
    composer = /^  \u2192 Add a follow-up.*\n/

    assert_match(/esc cancel/, box)
    assert_nil obstacle(box)
    assert_nil obstacle(box.sub(composer, ''))
    assert_nil obstacle(box.lines.first(9).join)
  end

  def test_a_dialog_under_cursor_s_follow_ups_box_still_counts
    box = Screens.session('cursor-follow-ups').lines.first(10).join

    assert_equal :dialog, obstacle(box + Screens.captured.fetch('cursor-120'))
    assert_equal :dialog, obstacle("#{box}  Do you trust the contents of this directory?\n")
  end

  def test_cursor_s_follow_up_editor_is_an_obstacle_above_its_composer
    editor = Keryx::Bell.reading(Screens.session('cursor-follow-up-editor'))

    assert_equal [:editor, "\"editing \u00b7 enter done \u00b7 esc close\", line 9 of 19"],
                 [editor.obstacle, editor.evidence]
    assert_equal :editor, obstacle(Screens::NARROW_EDITOR)
    assert_equal :editor, obstacle(Screens::NARROW_EDITOR.lines.first(6).join)
  end

  def test_the_editor_s_footer_outside_its_box_is_no_obstacle
    quoted = "  Cursor shows editing \u00b7 enter done \u00b7 esc close while a follow-up is edited.\n"
    box = Screens.session('cursor-follow-ups')

    assert_nil obstacle("#{quoted}\n\u203a Ask Codex to do anything\n")
    assert_nil obstacle(quoted + box)
    assert_nil obstacle(box.sub(/^(.*Running.*)$/) { "#{it}\n#{quoted.chomp}" })
  end

  def test_the_evidence_names_the_words_and_the_line_and_not_the_rest_of_the_line
    phrase = "  ok\n  private words, then Continue without trusting, then more private words\n"
    option = "  Pick one\n\n\u203a 1. private option\n  2. another private option\n"

    assert_equal '"Continue without trusting", line 2 of 2', evidence(phrase)
    assert_equal 'a marked option on line 3 of 4', evidence(option)
    assert_equal "\"\u00b7 esc cancel\", line 1 of 1", evidence("  private \u00b7 esc cancel private\n")
    assert_equal "\"ente r conf irm \u00b7 esc skip\", line 14 of 20", evidence(Screens::TINY_CODEX_HOOKS)
  end

  def test_the_evidence_shows_control_characters
    assert_equal "\"enterconfirm^G\u00b7 esc skip\", line 1 of 1", evidence("  enterconfirm\a\u00b7 esc skip\n")
  end

  def test_a_pane_too_narrow_to_tell_has_no_evidence
    assert_equal [:cramped, nil], Keryx::Bell.reading(Screens::TINY_QUESTION).to_h.values_at(:obstacle, :evidence)
  end
end
