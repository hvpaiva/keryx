# frozen_string_literal: true

require 'test_helper'

class SpawnDialogTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers

  TRUST = ["\u26a0 Workspace Trust Required",
           'Cursor Agent can execute code and access files in this directory.',
           'Do you trust the contents of this directory?', '/home/user/work/new-folder',
           "\u25b6 [a] Trust this workspace", '[q] Quit',
           'Use arrow keys to navigate, Enter to select, or press the key shown'].freeze
  EDIT = ["\u256d#{'-' * 30}", '| Edit file notes.md |', '| Do you want to make this edit? |',
          "| \u276f 1. Yes |", '|   2. No |'].join("\n").freeze

  # The command herdr typed, the first prompt last, wrapped at 120 columns, above what the harness shows.
  def typed(screen, prompt)
    first, rest = screen.split("\n", 2)
    command, shown = first.start_with?('$ ') ? [first, rest] : ['$ harness', screen]
    [*"#{command} -- '#{prompt}'".scan(/.{1,120}/), shown].join("\n")
  end

  # herdr reports the agent blocked, and each visible read of the pane shows what the block gives for that read.
  def stops_at(capture = nil, &screen)
    screen ||= ->(_read) { capture }
    reads = 0
    herdr.on_start = lambda do |socket, pane, _name, kind|
      herdr.put(socket, pane, agent(pane, kind, 'blocked'))
      prompt = herdr.starts.last[:arguments].last
      herdr.views[[socket, pane]] = -> { screen.call(reads += 1)&.then { typed(it, prompt) } }
    end
  end

  def from_keryx(name) = store.unread(name).select { it.from == 'keryx@athena' }

  def notices(result) = result.err.scan('Its text follows.').size

  def quoted(lines) = lines.map { "  #{it}" }.join("\n")

  def test_the_address_spawn_acts_for_gets_one_message_with_the_dialog_however_long_it_shows
    orq = join_claude('orq', 111)
    stops_at(Screens.captured.fetch('cursor-120'))
    result = spawn('rev-1', '--harness', 'cursor', '--timeout', '5s', 'Review it', env: orq)
    told = from_keryx('orq')
    bell = "[keryx] New message for orq@athena from keryx@athena (#{told.first.id}). Run 'keryx read " \
           "#{told.first.id}' to open it."

    assert_equal [3, 1, 1], [result.status, told.size, notices(result)]
    assert_equal 'Pane w1:p2, where spawn started rev-1@athena, stops at a dialog, and the session joins once it is ' \
                 "answered; keryx never answers one. Its text follows.\n\n#{quoted(TRUST)}\n\nTake it to your " \
                 "human, and answer it with 'herdr pane send-keys' only on their word.", told.first.body
    assert_includes sockets.posts, ['/tmp/cc-111.sock', bell]
  end

  def test_the_notice_quotes_the_dialog_on_stderr_once
    orq = join_claude('orq', 111)
    stops_at(Screens.captured.fetch('cursor-120'))
    result = spawn('rev-1', '--harness', 'cursor', '--timeout', '3s', env: orq)

    assert result.err.start_with?('Pane w1:p2 shows a dialog, and rev-1@athena joins once it is answered; keryx ' \
                                  "never answers one. Its text follows.\n#{quoted(TRUST)}\n")
  end

  def test_with_as_the_as_address_gets_the_message_instead_of_the_callers_own
    join_claude('orq', 111)
    store.create_address('person')
    stops_at(Screens.captured.fetch('codex-120'))
    result = spawn('impl', '--harness', 'codex', '--as', 'orq', '--timeout', '3s')

    assert_equal 3, result.status
    assert_equal [1, 0], [from_keryx('orq').size, from_keryx('person').size]
  end

  def test_a_caller_with_no_address_gets_no_message_and_spawn_times_out_with_the_dialog
    stops_at(Screens.captured.fetch('claude-120'))
    result = spawn('rev-1', '--harness', 'claude', '--timeout', '3s')

    assert_equal [3, 1, ['rev-1']], [result.status, notices(result), store.address_names]
    assert_includes result.err, "\nerror: rev-1@athena has not joined yet: pane w1:p2 shows the dialog below, and " \
                                'the session joins by itself once it is answered; keryx never answers one' \
                                "\n  Accessing workspace:\n"
    assert result.err.end_with?("\n  Yes, I trust this folder\n  Enter to confirm \u00b7 Esc to cancel\n")
  end

  def test_a_read_that_is_not_yet_a_dialog_posts_nothing_and_a_later_one_posts_once
    orq = join_claude('orq', 111)
    told = []
    stops_at do |read|
      told << from_keryx('orq').size
      read < 3 ? "$ codex\n" : Screens.captured.fetch('codex-120')
    end
    result = spawn('impl', '--harness', 'codex', '--timeout', '5s', env: orq)

    assert_equal [3, 1], [result.status, notices(result)]
    assert_equal [0, 0, 0, 1], told
  end

  def test_control_characters_in_the_read_show_as_caret_escapes
    orq = join_claude('orq', 111)
    stops_at(Screens.captured.fetch('codex-120').sub('Hooks need review', "\e[1mHooks need review\e[0m"))
    result = spawn('impl', '--harness', 'codex', '--timeout', '3s', env: orq)

    assert_includes result.err, "\n  ^[[1mHooks need review^[[0m\n"
    refute_includes result.err, "\e"
    assert_includes from_keryx('orq').first.body, "\n  ^[[1mHooks need review^[[0m\n"
  end

  def test_the_timeout_error_quotes_the_dialog_read_at_the_deadline_when_it_changed
    stops_at { it == 1 ? Screens.captured.fetch('cursor-120') : EDIT }
    result = spawn('rev-1', '--harness', 'claude', '--timeout', '3s')
    error = result.err[/^error: .*/m]

    assert_includes result.err, "\n  Do you trust the contents of this directory?\n"
    assert error.end_with?("never answers one\n  | Edit file notes.md |\n  | Do you want to make this edit? |\n  " \
                           "| \u276f 1. Yes |\n  | 2. No |\n")
  end

  def test_the_timeout_error_keeps_the_notice_dialog_when_the_last_read_fails
    stops_at { it == 1 ? Screens.captured.fetch('cursor-120') : nil }
    result = spawn('rev-1', '--harness', 'claude', '--timeout', '3s', 'Review it')
    id = store.unread('rev-1').first.id

    assert_includes result.err, "once it is answered; keryx never answers one; the request #{id} waits in its " \
                                "mailbox\n#{quoted(TRUST)}\n"
    assert result.err.end_with?("never answers one; the request #{id} waits in its mailbox\n#{quoted(TRUST)}\n")
  end

  def test_a_cramped_pane_quotes_nothing_and_posts_nothing
    orq = join_claude('orq', 111)
    session_runs(screen: Screens.captured.fetch('cursor-4'))
    result = spawn('impl', '--harness', 'cursor', '--timeout', '3s', env: orq)

    assert_equal 1, result.err.scan('is too narrow to tell whether it shows a dialog, such as').size
    assert_equal [0, []], [notices(result), from_keryx('orq')]
  end

  def test_a_queued_message_being_edited_is_reported_once_and_posted_to_no_one
    orq = join_claude('orq', 111)
    session_runs(screen: Screens.session('cursor-follow-up-editor'))
    result = spawn('impl', '--harness', 'cursor', '--timeout', '3s', env: orq)

    assert_equal 3, result.status
    assert_equal 1, result.err.scan('shows a queued message being edited; keryx types nothing').size
    assert_equal [0, []], [notices(result), from_keryx('orq')]
  end

  def test_a_blocked_agent_whose_pane_is_too_narrow_to_read_is_reported_as_such
    orq = join_claude('orq', 111)
    stops_at(Screens.captured.fetch('claude-4'))
    result = spawn('impl', '--harness', 'claude', '--timeout', '3s', env: orq)

    assert_equal 1, result.err.scan('is too narrow to tell whether it shows a dialog, such as').size
    assert_match(/pane w1:p2 is too narrow to tell whether it shows a dialog; look at it, and the session joins by /,
                 result.err)
    assert_equal [0, []], [notices(result), from_keryx('orq')]
  end

  def test_a_message_spawn_cannot_post_is_a_warning_and_spawn_still_waits
    orq = join_claude('orq', 111)
    File.chmod(0o500, tmp('state', 'addresses', 'orq', 'mail'))
    stops_at(Screens.captured.fetch('codex-120'))
    result = spawn('impl', '--harness', 'codex', '--timeout', '3s', env: orq)

    assert_equal 3, result.status
    assert_match(/^spawn could not tell orq about the dialog in pane w1:p2: Permission denied/, result.err)
  ensure
    File.chmod(0o700, tmp('state', 'addresses', 'orq', 'mail'))
  end
end
