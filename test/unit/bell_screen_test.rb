# frozen_string_literal: true

require 'test_helper'

class BellScreenTest < Minitest::Test
  WORKING = Screens.session('codex-working-transcript')
  # The Codex capture above its composer: a tool's output that quotes the hooks screen and the folder trust.
  TRANSCRIPT = WORKING.lines.take_while { !it.start_with?("\u203a") }.join
  # Codex shows each prompt sent to it in its transcript, where it looks like its composer.
  PROMPTED = "#{TRANSCRIPT}\u203a Check the hooks screen again\n\n".freeze

  def obstacle(screen) = Keryx::Bell.obstacle(screen)

  # The words a reading quotes and where they or a marked option are.
  def evidence(screen) = Keryx::Bell.reading(screen).then { [it.evidence, it.place] }

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

    assert_equal [:editor, "editing \u00b7 enter done \u00b7 esc close", 'line 9 of 19'],
                 [editor.obstacle, editor.evidence, editor.place]
    assert_equal :editor, obstacle(Screens::NARROW_EDITOR)
    assert_equal :editor, obstacle(Screens::NARROW_EDITOR.lines.first(6).join)
  end

  # A queued message taller than the pane puts the box's title above the top of the screen.
  def test_cursor_s_follow_up_editor_counts_when_its_title_is_above_the_screen
    [Screens.session('cursor-follow-up-editor'), Screens::NARROW_EDITOR].each do |screen|
      lines = screen.lines
      title = lines.index { it.include?('follow-ups') }
      footer = lines.index { it.include?('editing') }
      bottom = lines.index { it.include?("\u2514") }

      [lines.drop(title + 1), lines.drop(footer), lines[(title + 1)..bottom]].each do |crop|
        assert_equal :editor, obstacle(crop.join), crop.join
      end
    end
  end

  def test_without_its_title_the_editor_s_footer_counts_only_in_the_frame_the_screen_starts_with
    framed = " \u2502 editing \u00b7 enter done \u00b7 esc close \u2502\n"
    composer = "  \u2192 Add a follow-up\n"

    assert_equal :editor, obstacle(framed + composer)
    assert_nil obstacle("  editing \u00b7 enter done \u00b7 esc close\n#{composer}")
    assert_nil obstacle("  ok\n#{framed}#{composer}")
  end

  def test_the_editor_s_footer_outside_its_box_is_no_obstacle
    quoted = "  Cursor shows editing \u00b7 enter done \u00b7 esc close while a follow-up is edited.\n"
    box = Screens.session('cursor-follow-ups')

    assert_nil obstacle("#{quoted}\n\u203a Ask Codex to do anything\n")
    assert_nil obstacle(quoted + box)
    assert_nil obstacle(box.sub(/^(.*Running.*)$/) { "#{it}\n#{quoted.chomp}" })
  end

  def test_codex_s_extra_thought_menu_is_a_dialog
    menu = Screens.session('codex-extra-thought-transcribed')

    assert_equal [nil, 'a marked option on line 11 of 15'], evidence(menu)
    assert_equal :dialog, obstacle(PROMPTED + menu)
  end

  def test_the_evidence_names_the_words_and_the_line_and_not_the_rest_of_the_line
    phrase = "  ok\n  private words, then Continue without trusting, then more private words\n"
    option = "  Pick one\n\n\u203a 1. private option\n  2. another private option\n"

    assert_equal ['Continue without trusting', 'line 2 of 2'], evidence(phrase)
    assert_equal [nil, 'a marked option on line 3 of 4'], evidence(option)
    assert_equal ["\u00b7 esc cancel", 'line 1 of 1'], evidence("  private \u00b7 esc cancel private\n")
    assert_equal ["ente r conf irm \u00b7 esc skip", 'line 14 of 20'], evidence(Screens::TINY_CODEX_HOOKS)
  end

  def test_the_evidence_shows_control_characters
    assert_equal ["enterconfirm^G\u00b7 esc skip", 'line 1 of 1'], evidence("  enterconfirm\a\u00b7 esc skip\n")
  end

  def test_a_pane_too_narrow_to_tell_has_no_evidence
    assert_equal [:cramped, nil, nil],
                 Keryx::Bell.reading(Screens::TINY_QUESTION).to_h.values_at(:obstacle, :evidence, :place)
  end

  DRAFT = 'PERSON DRAFT do not submit'
  # Cursor's screen in evidence/05-bell.txt of the R44 report, whose draft a bell typed through herdr sent with it.
  CURSOR_DRAFT = Screens.session('cursor-draft')
  WRAPPED = "#{DRAFT}, and it runs on past the right edge of the pane".freeze
  # Claude Code idle under an answer that quotes no dialog.
  CLAUDE_DONE = "\u23fa Done.\n#{Screens::CLAUDE_IDLE.lines.drop(2).join}".freeze

  def reading(screen) = Keryx::Bell.reading(screen).to_h.values_at(:obstacle, :evidence, :place)

  def claude(composer, screen = CLAUDE_DONE) = screen.sub("\u276f ", composer)

  def test_a_person_s_draft_in_cursor_s_composer_is_an_obstacle_that_quotes_none_of_it
    assert_equal [:draft, nil, 'line 2 of 6'], reading(CURSOR_DRAFT)
    assert_equal 'the screen shows text typed in the composer (line 2 of 6)', Keryx::Bell.reading(CURSOR_DRAFT).note
  end

  def test_each_harness_s_empty_composer_and_its_placeholders_are_no_draft_unlike_text_typed_there
    cursor = ['Add a follow-up', "Add a follow-up \u2014 /plan to review and build", 'Plan, search, build anything',
              "Add a follow-up#{' ' * 57}ctrl+c to stop"].map { CURSOR_DRAFT.sub(DRAFT, it) }
    codex = ['Ask Codex to do anything', 'Ask a follow-up question'].map { WORKING.sub('Ask Codex to do anything', it) }
    queued = ['Press up to edit queued messages', 'Press up to edit queued messages, Enter to send them immediately',
              'Press up to select a queued message, then Enter to edit it',
              'Press up to select a queued message to edit, or Enter to send them now']
    claudes = ["\u276f", "\u276f ", "\u276f Try \"how does lib/keryx/bell.rb work?\"", *queued.map { "\u276f #{it}" }]
    drafts = [claude("\u276f #{DRAFT}"), WORKING.sub('Ask Codex to do anything', DRAFT), CURSOR_DRAFT]

    assert_equal(%i[draft draft draft], drafts.map { obstacle(it) })
    [*cursor, *codex, *claudes.map { claude(it) }].each { assert_nil obstacle(it), it }
  end

  # Each harness draws its input after its prompt, so a draft wider than the pane, or broken by a newline, goes on at
  # the text's column, as an entry of a menu would, and only the line with the prompt is given.
  def test_a_draft_wrapped_or_broken_over_lines_counts_at_its_prompt
    cursor = CURSOR_DRAFT.sub(DRAFT, WRAPPED.sub(' pane', "\n    pane"))
    wrapped = claude("\u276f #{WRAPPED.sub(' pane', "\n  pane")}")
    broken = claude("\u276f\n  #{DRAFT}")

    assert_equal([[:draft, nil, 'line 2 of 7'], [:draft, nil, 'line 4 of 7'], [:draft, nil, 'line 4 of 7']],
                 [cursor, wrapped, broken].map { reading(it) })
    assert_equal [:draft, nil, 'line 6 of 9'], reading("\u276f An older prompt\n\n#{wrapped}")
  end

  def test_neither_cursor_s_follow_ups_box_nor_a_dialog_s_options_read_as_a_draft
    box = Screens.session('cursor-follow-ups')
    picked = box.sub("\u25cb Also", "\u203a Also")
    dialogs = %w[claude-write claude-review codex-approval codex-hooks].map { Screens.real(it) }

    assert_equal [:draft, nil, 'line 15 of 19'], reading(box.sub('Add a follow-up', DRAFT))
    assert_equal [nil, nil], [obstacle(picked), obstacle(picked.lines.first(10).join)]
    assert_equal([:dialog] * 5, [*dialogs, Screens.session('codex-extra-thought-transcribed')].map { obstacle(it) })
  end

  def test_a_narrow_dialog_under_an_older_prompt_defers_as_a_draft_and_quotes_nothing
    narrow = %w[claude-4 cursor-4 cursor-5 cursor-6 cursor-7 cursor-8 cursor-9 cursor-10 cursor-11 cursor-12]

    assert_equal narrow.sort, Screens.captured.reject { |_name, screen|
      obstacle(PROMPTED + screen) == :dialog
    }.keys.sort
    narrow.each { assert_equal [:draft, nil], reading(PROMPTED + Screens.captured.fetch(it)).first(2), it }
  end

  # A menu with no phrase or footer keryx knows reads as a draft at the entry its arrow marks. A wrapped draft hides the
  # composer from the search for a dialog, which then starts at an older prompt, or at the top when none shows, so a
  # dialog's words on those lines, here quoted in the transcript, read as a dialog. The bell waits on both.
  def test_each_known_limit_of_reading_a_draft_errs_toward_waiting
    wrapped = claude("\u276f #{WRAPPED.sub(' pane', "\n  pane")}", Screens::CLAUDE_IDLE)

    assert_equal [:draft, nil, 'line 1 of 2'], reading("\u203a Trust\n  Quit\n")
    assert_equal [:dialog, 'Do you trust', 'line 1 of 8'], reading(wrapped)
  end
end
