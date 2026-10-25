# frozen_string_literal: true

require 'test_helper'

class DialogTest < Minitest::Test
  EXTRA = 'Read docs/brief.md first, keep notes in docs/notes.md, and say what you found and what you could not check.'
  PROMPT = Keryx::Harness.first_prompt('rev-1.dev@athena', name: 'rev-1.dev', role: 'reviewer', extra: EXTRA)
  CORNER = "\u256d"
  BAR = "\u2500"

  def self.quoted(text) = "'#{text.gsub("'", %q('"'"'))}'"

  # The pane as herdr leaves it: the command it typed, the first prompt last and wrapped at the pane's width, then the
  # harness's screen, whose own "$ ..." line, when it has one, is that command's start.
  def typed(capture, width: 120, above: '')
    first, rest = capture.split("\n", 2)
    command, screen = first.start_with?('$ ') ? [first, rest] : ['$ codex', capture]
    [*"#{command} -- #{DialogTest.quoted(PROMPT)}".scan(/.{1,#{width}}/), above + screen].join("\n")
  end

  def excerpt(read, prompt = PROMPT) = Keryx::Dialog.excerpt(read, prompt)

  def assert_within_caps(lines)
    assert_operator lines.size, :<=, Keryx::Dialog::LINES
    assert_empty(lines.reject { it.size <= Keryx::Dialog::WIDTH })
  end

  def test_cursor_trust_box_is_quoted_whole_without_the_command
    lines = excerpt(typed(Screens.captured.fetch('cursor-120')))

    assert_equal ["\u26a0 Workspace Trust Required",
                  'Cursor Agent can execute code and access files in this directory.',
                  'Do you trust the contents of this directory?', '/home/user/work/new-folder',
                  "\u25b6 [a] Trust this workspace", '[q] Quit',
                  'Use arrow keys to navigate, Enter to select, or press the key shown'], lines
    assert_within_caps lines
  end

  def test_claude_folder_trust_is_quoted_from_below_its_rule
    lines = excerpt(typed(Screens.captured.fetch('claude-120')))

    assert_equal 'Accessing workspace:', lines.first
    assert_includes lines, 'Quick safety check: Is this a project you created or one you trust? (Like your own code, ' \
                           'a well-known open source'
    assert_equal ["\u276f No, exit", 'Yes, I trust this folder', "Enter to confirm \u00b7 Esc to cancel"],
                 lines.last(3)
    refute(lines.any? { it.include?('claude') || it.include?('keryx') })
    assert_within_caps lines
  end

  def test_codex_hooks_screen_is_quoted_with_its_options_and_footer
    lines = excerpt(typed(Screens.captured.fetch('codex-120')))

    assert_equal ['Hooks need review', '6 hooks are new or changed.',
                  'Hooks can run outside the sandbox after you trust them.', "\u203a 1. Review hooks",
                  '2. Trust all and continue', "3. Continue without trusting (hooks won't run)",
                  "enter confirm \u00b7 esc skip"], lines
  end

  def test_harness_output_above_a_box_or_a_rule_is_left_out
    cursor = excerpt(typed(Screens.captured.fetch('cursor-120'), above: "Cursor Agent 2026.10\n#{BAR * 40}\nLoading\n"))
    claude = excerpt(typed(Screens.captured.fetch('claude-120'), above: " Claude Code v2.1\n#{CORNER}#{BAR}\n"))

    assert_equal "\u26a0 Workspace Trust Required", cursor.first
    assert_equal 'Accessing workspace:', claude.first
  end

  def test_a_narrow_read_quotes_the_bottom_of_the_dialog_it_holds
    cursor = excerpt(typed(Screens.captured.fetch('cursor-14'), width: 14))
    codex = excerpt(typed(Screens.captured.fetch('codex-14'), width: 14))

    assert_equal ['Use', 'arro', 'w', 'keys', 'to', 'navi', 'gate', ', En', 'ter', 'to', 'sele', 'ct,', 'or p', 'ress',
                  'the', 'key', 'sho', 'wn'], cursor
    assert_equal ['after you', 'trust', 'them.', "\u203a 1. Review", 'hooks', '2. Trust all', 'and', 'continue',
                  '3. Continue', 'without', 'trusting', '(hooks', "won't", 'run)', 'enter', "confirm \u00b7",
                  'esc skip'], codex
  end

  def test_a_tall_dialog_keeps_its_last_lines_and_a_long_line_is_cut
    box = (1..40).map { "| file #{it}.rb #{'x' * (it == 39 ? 300 : 10)} |" }
    read = typed(["#{CORNER}#{BAR * 20}", *box, '| Do you want to proceed? |',
                  "| \u276f 1. Yes |", '|   2. No |'].join("\n"))
    lines = excerpt(read)

    assert_equal ['| Do you want to proceed? |', "| \u276f 1. Yes |", '| 2. No |'], lines.last(3)
    assert_equal "| file 39.rb #{'x' * 146}\u2026", lines[-5]
    assert_within_caps lines
    assert_equal Keryx::Dialog::LINES, lines.size
  end

  def test_control_characters_in_the_read_show_as_caret_escapes
    read = typed(Screens.captured.fetch('codex-120').sub('Hooks need review', "\e[1mHooks need review\e[0m\a"))

    assert_equal '^[[1mHooks need review^[[0m^G', excerpt(read).first
  end

  def test_dialog_words_in_the_first_prompt_are_not_a_dialog
    prompt = "#{PROMPT} Press enter to confirm (y/n) when you trust the folder."
    read = "$ claude -- #{DialogTest.quoted(prompt)}\n\n> \n"

    assert_equal :dialog, Keryx::Bell.obstacle(read)
    assert_nil excerpt(read, prompt)
    assert_nil excerpt(typed("$ claude\n> \n"))
  end

  def test_a_read_that_has_lost_the_command_is_taken_whole
    assert_equal ['Hooks need review', "\u203a 1. Review hooks"],
                 excerpt("  Hooks need review\n\u203a 1. Review hooks\n", 'nothing on the screen ends with this')
    assert_equal ['Hooks need review', '1. Review hooks'], excerpt("Hooks need review\n1. Review hooks\n", '')
  end
end
