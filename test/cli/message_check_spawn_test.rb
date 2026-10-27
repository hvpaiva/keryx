# frozen_string_literal: true

require 'test_helper'

# spawn checks its brief before it opens a pane, and its notice about a dialog is keryx's own, never checked.
class MessageCheckSpawnTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers
  include MessageCheckHelpers

  def setup
    super
    @orq = join_claude('orq.dev', 111)
  end

  # herdr reports the new session blocked at Cursor's folder trust, typed under the command that started it.
  def stops_at_a_dialog
    herdr.on_start = lambda do |socket, pane, _name, kind|
      herdr.put(socket, pane, agent(pane, kind, 'blocked'))
      typed = "$ harness -- '#{herdr.starts.last[:arguments].last}'".scan(/.{1,120}/)
      herdr.views[[socket, pane]] = [*typed, Screens.captured.fetch('cursor-120')].join("\n")
    end
  end

  def test_spawn_runs_the_checker_once_on_the_brief_it_delivers
    session_joins
    accepting

    assert_checked(spawn('rev-1.dev', '--harness', 'claude', 'Review PR #448', env: @orq), 'spawn', 'rev-1.dev')
  end

  def test_a_refused_brief_opens_no_pane
    refusing
    result = spawn('rev-1.dev', '--harness', 'claude', 'Review PR #448', env: @orq)

    assert_refused(result)
    assert_empty store.stored('rev-1.dev')
    assert_empty herdr.splits
    assert_empty herdr.starts
  end

  def test_after_a_refused_brief_a_second_spawn_of_the_name_with_an_accepting_checker_succeeds
    refusing
    spawn('rev-1.dev', '--harness', 'claude', 'Review PR #448', env: @orq)
    session_joins
    accepting
    result = spawn('rev-1.dev', '--harness', 'claude', 'Review PR #448 again', env: @orq)

    assert_equal [0, ''], [result.status, result.err]
    assert_match(/\ASpawned rev-1.dev@athena as a claude session in pane w1:p2, and it joined\.\n/, result.out)
    assert_equal(['Review PR #448 again'], store.stored('rev-1.dev').map { it.message.body })
  end

  def test_spawns_notice_of_a_dialog_is_delivered_past_a_refusing_checker
    stops_at_a_dialog
    refusing
    result = spawn('rev-1.dev', '--harness', 'cursor', '--timeout', '3s', env: @orq)
    told = store.stored('orq.dev').map(&:message)

    assert_equal 3, result.status
    assert_equal(['keryx.system@athena'], told.map(&:from))
    assert_match(/\APane w1:p2, where spawn started rev-1.dev@athena, stops at a dialog/, told.first.body)
    refute_path_exists record
  end
end
