# frozen_string_literal: true

module Screens
  # Codex 0.163's hooks screen as herdr's detection source shows it in a pane 14 columns wide.
  NARROW_CODEX_HOOKS = [
    '  after you', '  trust', '  them.', '', '', "\u203a 1. Review", '     hooks', '  2. Trust all', '     and',
    '     continue', '  3. Continue', '     without', '     trusting', '     (hooks', "     won't", '     run)', '',
    '  enter', "  confirm \u00b7", '  esc skip'
  ].join("\n")
  # The same screen in a pane 6 columns wide, where Codex breaks the words too.
  TINY_CODEX_HOOKS = [
    '  ru', '  n', '  ou', '  ts', '  id', '  e', '  th', '  e', '  sa', "  [\u2026", "\u203a 1.", '     R', '     e',
    '  ente', '  r', '  conf', '  irm', "  \u00b7", '  esc', '  skip'
  ].join("\n")
  # A question with no footer in a pane 5 columns wide, its words broken.
  TINY_QUESTION = "  Do\n  you\n  tru\n  st\n  thi\n  s\n  fol\n  der\n  ?\n"
  # A question wrapped inside a box border, one word or two per line.
  NARROW_BOX = "\u2502 Do          \u2502\n\u2502 you trust   \u2502\n\u2502 this folder?\u2502\n"
  # A question hard wrapped at 14 columns with no footer, so only its options show it is one.
  WRAPPED_OPTIONS = "Trust this wor\nkspace?\n\u203a Yes\n  No\n"
  # Claude Code idle under its last answer, which quotes dialogs: its composer between two rules, then its mode.
  CLAUDE_IDLE = [
    "\u23fa The folder trust asks \"Do you trust this folder?\" and ends with \"Enter to confirm \u00b7 Esc to",
    '  cancel".', '', "\u2500" * 80, "\u276f ", "\u2500" * 80,
    "  \u23f5\u23f5 bypass permissions on (shift+tab to cycle)"
  ].join("\n")
  # Cursor's follow-ups box in a pane 22 columns wide, a message being edited in it and its footer wrapped.
  NARROW_EDITOR = [
    " \u250c\u2500 follow-ups \u2500\u2500\u2500\u2500\u2500\u2510", " \u2502 \u203a Also say which \u2502",
    " \u2502   folder you are \u2502", " \u2502 +2 more lines \u00b7  \u2502", " \u2502 editing \u00b7 enter  \u2502",
    " \u2502 done \u00b7 esc close \u2502", " \u2514#{"\u2500" * 18}\u2518", '', "  \u2192 Add a follow-up"
  ].join("\n")
  CAPTURES = File.expand_path('../fixtures/screens', __dir__)
  SESSIONS = File.join(CAPTURES, 'sessions')

  # Claude Code's folder trust, Codex's hooks screen and Cursor's workspace trust as the bell reads them from herdr,
  # at 120 columns and at every width from 4 to 14, named HARNESS-WIDTH. The files escape what is not ASCII.
  def self.captured
    @captured ||= Dir[File.join(CAPTURES, '*.txt')].to_h { [File.basename(it, '.txt'), unescaped(File.read(it))] }
  end

  # Sessions at work or idle as the bell reads them from herdr, their paths made neutral: Codex 0.163.0 working
  # under a transcript that quotes dialogs (codex-working-transcript), Cursor idle (cursor-idle), and Cursor working
  # with a message queued in its follow-ups box (cursor-follow-ups) and with that message being edited there
  # (cursor-follow-up-editor). codex-extra-thought-transcribed, the menu Codex 0.163.0 shows mid-turn while it gives a
  # request extra thought, was transcribed by hand from a screenshot, not captured.
  def self.session(name) = unescaped(File.read(File.join(SESSIONS, "#{name}.txt")))

  # Dialogs read from real Claude Code and Codex panes on 2026-10-26 with their rules shortened, copied from Iris's
  # test/support/real_dialogs.rb in ~/dev/personal/inbox, at branch ui/attention 39800b4 (commit 01438b0), which is not
  # on its main: claude-write, claude-review, codex-approval and codex-hooks.
  def self.real(name) = unescaped(File.read(File.join(CAPTURES, 'real', "#{name}.txt")))

  def self.unescaped(text) = text.gsub(/\\u(\h{4})/) { ::Regexp.last_match(1).hex.chr('UTF-8') }
end
