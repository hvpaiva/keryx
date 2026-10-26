# frozen_string_literal: true

require 'test_helper'

class SpawnWorkspaceTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers

  LABELS = { 'w1' => 'home', 'w2' => 'alpha' }.freeze

  def spawn_in(workspace, *argv) = spawn('rev-1.alpha', '--harness', 'claude', '--workspace', workspace, *argv)

  def slow(call, seconds = 5)
    herdr.on_call = ->(name) { clock.advance(seconds) if name == call }
  end

  def test_a_session_in_another_workspace_gets_a_new_tab_there_though_this_tab_has_room
    workspace({ %w[w1:t1 main] => { 'w1:p1' => AREA }, %w[w2:t1 notes] => { 'w2:p2' => AREA } }, LABELS)
    session_joins
    result = spawn_in('alpha')

    assert_equal 0, result.status, result.err
    assert_empty herdr.splits
    assert_equal [['w2', 'rev-1.alpha', '/work', session_env]], herdr.created_tabs
    assert_equal %w[w2:p3 w2:t2], [herdr.starts.first[:pane], herdr.pane(SOCKET, 'w2:p3').tab]
    assert_equal [[SOCKET, 'w2:p3', 'rev-1.alpha']], herdr.renames
    assert_empty herdr.created_workspaces
  end

  def test_tab_in_another_workspace_splits_the_pane_with_the_most_room_of_its_tabs_with_that_label
    workspace({ %w[w1:t1 main] => { 'w1:p1' => AREA }, %w[w1:t2 reviews] => { 'w1:p2' => AREA },
                %w[w2:t1 reviews] => { 'w2:p3' => [120, 48] }, %w[w2:t2 reviews] => { 'w2:p4' => [166, 48] } },
              LABELS)
    session_joins
    result = spawn_in('alpha', '--tab', 'reviews')

    assert_equal 0, result.status, result.err
    assert_equal %w[w2:p3 w2:p4], herdr.layouts
    assert_equal([%w[w2:p4 right]], herdr.splits.map { it.first(2) })
    assert_empty herdr.created_tabs
  end

  def test_tab_in_another_workspace_without_that_label_there_opens_it_there_not_in_this_one
    workspace({ %w[w1:t1 main] => { 'w1:p1' => AREA }, %w[w1:t2 reviews] => { 'w1:p2' => AREA },
                %w[w2:t1 notes] => { 'w2:p3' => AREA } }, LABELS)
    session_joins
    result = spawn_in('alpha', '--tab', 'reviews')

    assert_equal 0, result.status, result.err
    assert_empty herdr.splits
    assert_equal [['w2', 'reviews', '/work', session_env]], herdr.created_tabs
  end

  def test_tab_in_another_workspace_whose_panes_are_too_narrow_opens_another_tab_with_that_label_there
    workspace({ %w[w1:t1 main] => { 'w1:p1' => AREA }, %w[w2:t1 reviews] => { 'w2:p2' => [120, 48] } },
              LABELS)
    session_joins
    spawn_in('alpha', '--tab', 'reviews', '--cwd', tmp('repo').tap { FileUtils.mkdir_p(it) })

    assert_empty herdr.splits
    assert_equal [['w2', 'reviews', tmp('repo'), session_env]], herdr.created_tabs
  end

  def test_a_missing_workspace_is_created_and_its_one_tab_takes_the_label_a_new_tab_would_have
    session_joins
    result = spawn_in('alpha')

    assert_equal 0, result.status, result.err
    assert_equal [['alpha', '/work', session_env]], herdr.created_workspaces
    assert_equal 'w2:p2', herdr.starts.first[:pane]
    assert_equal [['w2:t1', 'rev-1.alpha']], herdr.renamed_tabs
    assert_equal [[SOCKET, 'w2:p2', 'rev-1.alpha']], herdr.renames
    assert_equal [[], []], [herdr.splits, herdr.created_tabs]
  end

  def test_a_created_workspace_tab_takes_the_tab_label_so_the_next_session_with_it_splits_there
    %w[rev-1.alpha rev-2.alpha].each_with_index do |name, index|
      session_joins(pid: 500 + index)

      assert_equal 0, spawn(name, '--harness', 'claude', '--workspace', 'alpha', '--tab', 'reviews').status
    end

    assert_equal [['w2:t1', 'reviews']], herdr.renamed_tabs
    assert_equal([%w[w2:p2 right]], herdr.splits.map { it.first(2) })
    assert_equal 1, herdr.created_workspaces.size
  end

  def test_a_tab_herdr_does_not_rename_is_a_notice_and_the_session_still_starts
    herdr.rename_tab_error = 'herdr tab rename failed: tab w2:t1 not found'
    session_joins
    result = spawn_in('alpha')

    assert_equal 0, result.status, result.err
    assert_equal 'Tab w2:t1 keeps the label herdr gave it, not rev-1.alpha: herdr tab rename failed: tab w2:t1 not ' \
                 "found.\n", result.err
    assert_equal 'w2:p2', herdr.starts.first[:pane]
  end

  def test_the_first_workspace_herdr_lists_with_the_label_is_used
    workspace({ %w[w1:t1 main] => { 'w1:p1' => AREA } }, LABELS.merge('w3' => 'alpha'))
    session_joins
    spawn_in('alpha')

    assert_equal(['w2'], herdr.created_tabs.map(&:first))
  end

  def test_naming_this_panes_workspace_places_the_session_as_without_the_option_though_another_comes_first
    workspace({ %w[w1:t1 main] => { 'w1:p1' => AREA } }, { 'w2' => 'alpha', 'w1' => 'alpha' })
    session_joins
    result = spawn_in('alpha')

    assert_equal 0, result.status, result.err
    assert_equal [['w1:p1', 'right', '/work', session_env]], herdr.splits
    assert_equal [[], []], [herdr.created_tabs, herdr.created_workspaces]
  end

  def test_without_workspace_spawn_lists_no_workspace_and_creates_none
    workspace({ %w[w1:t1 main] => { 'w1:p1' => AREA }, %w[w1:t2 reviews] => { 'w1:p2' => [120, 48] } },
              LABELS)
    %w[rev-1.dev rev-2.dev].each_with_index do |name, index|
      session_joins(pid: 500 + index)

      assert_equal 0, spawn(name, '--harness', 'claude', *(['--tab', 'reviews'] if index == 1)).status
    end

    assert_equal ['w1:p1'], herdr.splits.map(&:first)
    assert_equal [['w1', 'reviews', '/work', session_env]], herdr.created_tabs
    assert_equal [0, [], []], [herdr.workspace_lists.size, herdr.created_workspaces, herdr.renamed_tabs]
  end

  def test_an_invalid_workspace_label_is_refused_before_spawn_creates_anything
    result = spawn_in(' alpha')

    assert_equal 2, result.status
    assert_match(/\Aerror: invalid workspace label " alpha": up to 40 letters, digits, spaces, dots, hyphens or /,
                 result.err)
    refute store.address?('rev-1.alpha')
    assert_equal [[], [], []], [herdr.workspace_lists, herdr.created_workspaces, herdr.created_tabs]
  end

  def test_a_timeout_that_passed_while_spawn_listed_the_workspaces_creates_none
    slow(:workspaces)
    result = spawn_in('alpha', '--timeout', '3s')

    assert_equal 3, result.status
    assert_match(/before spawn opened a pane; it started no session for rev-1.alpha@athena$/, result.err)
    assert_equal [[], []], [herdr.created_workspaces, herdr.starts]
  end

  def test_a_workspace_created_as_the_timeout_passes_keeps_its_labels_and_holds_only_a_shell
    slow(:create_workspace)
    result = spawn_in('alpha', '--timeout', '3s')

    assert_equal 3, result.status
    assert_match(/\Aerror: the timeout passed after spawn opened pane w2:p2, and it started no claude session there; /,
                 result.err)
    assert_equal [[], [], []], [herdr.renamed_tabs, herdr.renames, herdr.starts]
  end
end
