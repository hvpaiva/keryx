# frozen_string_literal: true

require 'test_helper'

# The courier telling a joined session's director that its herdr pane shows a dialog.
class CourierDialogTest < Minitest::Test
  include TempDir
  include Factory
  include CourierHelpers

  SOCKET = '/h.sock'
  PANE = 'w1:p2'
  FREE = "\u2022 Done.\n\n\u276f \n"
  ANSWER = 'keryx never answers a dialog. If your human lets you answer the dialogs of the sessions you direct, ' \
           "answer it with 'herdr pane send-keys w1:p2 KEY...'; otherwise take it to your human, and answer it only " \
           'on their word. keryx tells you again only when the pane shows a new dialog.'

  def member(director: 'orq.dev', pane: PANE, name: 'impl.dev')
    store.create_address(name)
    fake_herdr.put(SOCKET, pane, Keryx::Herdr::Agent.new(pane:, kind: 'claude', status: 'blocked'))
    store.bind(name, build_occupant(session_id: "session-#{name}", herdr_socket: SOCKET, herdr_pane: pane, director:))
  end

  def show(screen, pane: PANE) = fake_herdr.views[[SOCKET, pane]] = screen

  def dialogs(round) = round.dialogs.map { [it.recipient, it.name, it.pane] }

  def bodies(name) = store.unread(name).select { it.from == 'keryx.system@athena' }.map(&:body)

  def test_a_dialog_is_told_to_the_director_once_with_its_text_and_the_session_is_told_nothing
    member
    show(Screens.real('claude-write'))
    first = courier.round

    assert_equal [['orq.dev@athena', 'impl.dev', PANE]], dialogs(first)
    assert_equal [[], []], [courier.round.dialogs, first.errors]
    assert_equal ['impl.dev@athena stops at a dialog in pane w1:p2 and waits until it is answered. Its text follows.' \
                  "\n\n  Create file\n  probe.txt\n  1 hi\n  Do you want to create probe.txt?\n  \u276f 1. Yes\n  2. " \
                  'Yes, and switch to accept edits (auto-approve file edits and common file commands) for this ' \
                  "session (shift+tab)\n  3. No\n  Esc to cancel \u00b7 Tab to amend\n\n#{ANSWER}"], bodies('orq.dev')
    assert_empty bodies('impl.dev')
  end

  def test_every_real_dialog_is_told_and_a_new_one_in_the_same_pane_is_told_again
    member
    told = %w[claude-write claude-review codex-approval codex-hooks].map do |name|
      show(Screens.real(name))
      dialogs(courier.round).size
    end

    assert_equal [1, 1, 1, 1], told
    assert_equal 4, bodies('orq.dev').size
    assert_includes bodies('orq.dev').find { it.include?("  Review your answers\n") }, "  \u2192 Sim, apague\n"
  end

  def test_the_same_dialog_is_told_again_once_a_read_showed_the_pane_without_it
    member
    show(Screens.real('codex-approval'))
    courier.round
    show(FREE)

    assert_empty courier.round.dialogs
    show(Screens.real('codex-approval'))

    assert_equal 1, courier.round.dialogs.size
    assert_equal 2, bodies('orq.dev').size
  end

  def test_a_moved_selection_or_a_counting_timer_is_the_same_dialog
    member
    screen = Screens.real('codex-approval')
    countdown = ->(left) { "#{screen}  Codex will automatically deny this request in #{left}\n" }
    show(countdown.call('0:28'))
    courier.round
    show(countdown.call('0:27').sub("\u203a 1.", '  1.').sub('  2. Yes, and', "\u203a 2. Yes, and"))

    assert_empty courier.round.dialogs
    assert_equal 1, bodies('orq.dev').size
  end

  def test_no_director_or_the_session_s_own_address_reads_no_pane_and_tells_nobody
    member(director: nil)
    member(director: 'rev-1.dev/abcdef', pane: 'w1:p3', name: 'rev-1.dev')
    reads = []
    [PANE, 'w1:p3'].each { |pane| show(-> { Screens.real('claude-write').tap { reads << pane } }, pane:) }

    assert_equal [[], [], []], [courier.round.dialogs, reads, bodies('orq.dev')]
  end

  def test_a_director_whose_session_left_is_told_at_the_address_it_held
    member(director: 'orq.dev/abcdef')
    show(Screens.real('claude-write'))

    assert_equal [['orq.dev@athena', 'impl.dev', PANE]], dialogs(courier.round)
  end

  def test_a_retired_director_is_told_nothing_and_reported_once
    member
    store.retire('orq.dev', by: 'person.local', now: Factory::NOW)
    show(Screens.real('claude-write'))
    first = courier.round
    second = courier.round

    assert_equal [[], ['did not tell orq.dev@athena about the dialog in pane w1:p2 of impl.dev@athena; ' \
                       'orq.dev@athena is retired; mail to it is refused']], [first.dialogs, first.errors]
    assert_equal [[], []], [second.dialogs, second.errors]
  end

  # None of them shows that the dialog told before is gone, so that dialog is not told again after them.
  def test_an_edited_message_a_cramped_screen_or_an_unread_pane_tells_nothing_and_keeps_the_record
    member
    show(Screens.real('claude-write'))
    courier.round
    told = [Screens::NARROW_EDITOR, Screens.captured.fetch('cursor-4'), nil].map do |screen|
      show(screen)
      courier.round.dialogs
    end
    show(Screens.real('claude-write'))

    assert_equal [[], [], [], []], [*told, courier.round.dialogs]
    assert_equal 1, bodies('orq.dev').size
  end

  # Codex's extra-thought menu, transcribed by hand from a screenshot (test/support/screens.rb), says no action is
  # required and closes by itself.
  def test_a_menu_that_needs_no_answer_is_not_told
    member
    show(Screens.session('codex-extra-thought-transcribed'))

    assert_equal [[], []], [courier.round.dialogs, bodies('orq.dev')]
  end

  # The second courier tells the dialog while the first is posting it, after both found it untold.
  def test_two_couriers_on_one_store_post_one_copy_and_only_one_reports_it
    member
    show(Screens.real('claude-write'))
    other = build_courier
    interleaved = nil
    mail = postman
    racing = Object.new
    racing.define_singleton_method(:post) do |**fields|
      interleaved ||= other.round
      mail.post(**fields)
    end

    assert_empty build_courier(mail: racing).round.dialogs
    assert_equal [['orq.dev@athena', 'impl.dev', PANE]], dialogs(interleaved)
    assert_equal 1, bodies('orq.dev').size
  end
end
