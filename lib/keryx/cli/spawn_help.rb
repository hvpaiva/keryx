# frozen_string_literal: true

require_relative '../spawner'
require_relative 'command'

module Keryx
  module CLI
    # The paragraphs of spawn's help that describe what Spawner does.
    module SpawnHelp
      NAMING = 'ADDRESS is MEMBER.TEAM, or MEMBER alone for a member of the team of the address spawn runs as, or ' \
               "else of the one team on this machine with that member. #{Command::NAME_SPELLING} herdr names the " \
               'agent MEMBER_TEAM, cut to 32 characters, since its agent names take no dot.'.freeze
      PLACEMENT = 'spawn runs in a herdr pane. Of the panes in this tab, or with --tab in every tab labelled LABEL, ' \
                  'it splits the one that leaves the new pane the most room along --split, provided the terminal in ' \
                  "the new pane gets at least #{Spawner::MIN_COLUMNS} columns and #{Spawner::MIN_ROWS} rows inside " \
                  "herdr's default borders and scrollbar, which keep a harness's dialogs and footer on whole lines; " \
                  'when no pane has that room, it opens a new tab labelled LABEL, or MEMBER.TEAM without --tab. ' \
                  'When herdr gives no layout for one of those panes, it opens that new tab too, and never splits a ' \
                  'pane it could not measure. Besides splitting, the only change spawn makes to a pane it did not ' \
                  'create is to clear the herdr name MEMBER_TEAM from the pane it runs in, which a session there ' \
                  'kept from an address it left. It labels the new pane MEMBER.TEAM.'.freeze
      WAITING = 'A dialog in the new pane, such as a folder trust or permission question, stops the session. spawn ' \
                'quotes the dialog once, on stderr and in a message from keryx to the address spawn runs as, when ' \
                'there is one, which rings that address, and keeps waiting; it never answers the dialog. The ' \
                'session holds its first prompt behind the dialog and joins once it is answered, even after spawn ' \
                'gave up. --timeout counts from the moment spawn starts, and spawn exits with status 3 when it ' \
                'passes before the join; its error reads the pane again and quotes the dialog it then shows, if ' \
                'any, or, when that read fails, the dialog spawn quoted earlier, as what the pane showed then. A ' \
                'herdr call already started may finish after it, but spawn checks the timeout before each next ' \
                'step and starts no harness once it passed, so a pane it opened by then holds only a shell.'
    end
  end
end
