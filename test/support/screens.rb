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
  # A question wrapped inside a box border, one word or two per line.
  NARROW_BOX = "\u2502 Do          \u2502\n\u2502 you trust   \u2502\n\u2502 this folder?\u2502\n"
end
