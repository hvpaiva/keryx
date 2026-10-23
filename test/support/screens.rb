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
  CAPTURES = File.expand_path('../fixtures/screens', __dir__)

  # Claude Code's folder trust, Codex's hooks screen and Cursor's workspace trust as the bell reads them from herdr,
  # at 120 columns and at every width from 4 to 14, named HARNESS-WIDTH. The files escape what is not ASCII.
  def self.captured
    @captured ||= Dir[File.join(CAPTURES, '*.txt')].to_h do |path|
      [File.basename(path, '.txt'), File.read(path).gsub(/\\u(\h{4})/) { ::Regexp.last_match(1).hex.chr('UTF-8') }]
    end
  end
end
