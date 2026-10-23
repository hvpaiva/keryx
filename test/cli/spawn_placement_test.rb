# frozen_string_literal: true

require 'test_helper'

class SpawnPlacementTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include SpawnHelpers

  def test_a_pane_with_room_for_two_sessions_is_split
    session_joins
    result = spawn('rev-1', '--harness', 'claude')

    assert_equal 0, result.status, result.err
    assert_equal [['w1:p1', 'right', '/work', session_env]], herdr.splits
    assert_equal [[103, 48], [102, 48]], herdr.sizes.values_at('w1:p1', 'w1:p2')
    assert_empty herdr.created_tabs
  end

  def test_the_pane_of_this_tab_with_the_most_room_is_split_even_when_it_is_not_this_one
    workspace(%w[w1:t1 main] => { 'w1:p1' => [200, 48], 'w1:p2' => [205, 48] })
    session_joins
    spawn('rev-1', '--harness', 'claude')

    assert_equal([%w[w1:p2 right]], herdr.splits.map { it.first(2) })
    assert_equal 'w1:p3', herdr.starts.first[:pane]
    assert_equal [[SOCKET, 'w1:p3', 'rev-1']], herdr.renames
    assert_equal [200, 48], herdr.sizes['w1:p1']
  end

  def test_a_pane_too_narrow_to_halve_opens_a_tab_named_after_the_session
    workspace(%w[w1:t1 main] => { 'w1:p1' => [120, 40] })
    session_joins
    result = spawn('rev-1', '--harness', 'claude')

    assert_equal 0, result.status, result.err
    assert_empty herdr.splits
    assert_equal [['w1', 'rev-1', '/work', session_env]], herdr.created_tabs
    assert_equal %w[w1:p2 w1:t2], [herdr.starts.first[:pane], herdr.pane(SOCKET, 'w1:p2').tab]
    assert_equal [[SOCKET, 'w1:p2', 'rev-1']], herdr.renames
  end

  def test_sessions_spawned_one_after_another_keep_every_pane_at_least_80_columns_wide
    %w[rev-1 rev-2 rev-3].each_with_index do |name, index|
      session_joins(pid: 500 + index)

      assert_equal 0, spawn(name, '--harness', 'claude').status
    end

    assert_equal ['w1:p1'], herdr.splits.map(&:first)
    assert_equal(%w[rev-2 rev-3], herdr.created_tabs.map { it[1] })
    assert_operator herdr.sizes.values.map(&:first).min, :>=, 80
  end

  def test_a_split_down_halves_the_height
    workspace(%w[w1:t1 main] => { 'w1:p1' => [205, 30], 'w1:p2' => [100, 50] })
    session_joins
    spawn('rev-1', '--harness', 'claude', '--split', 'down')

    assert_equal([%w[w1:p2 down]], herdr.splits.map { it.first(2) })
    assert_equal [[100, 25], [100, 25]], herdr.sizes.values_at('w1:p2', 'w1:p3')
  end

  def test_a_pane_too_short_to_halve_down_opens_a_tab
    workspace(%w[w1:t1 main] => { 'w1:p1' => [205, 47] })
    session_joins
    spawn('rev-1', '--harness', 'claude', '--split', 'down')

    assert_empty herdr.splits
    assert_equal(['rev-1'], herdr.created_tabs.map { it[1] })
  end

  def test_a_tab_label_whose_panes_are_too_narrow_opens_another_tab_with_that_label
    workspace(%w[w1:t1 main] => { 'w1:p1' => AREA }, %w[w1:t2 agents] => { 'w1:p2' => [120, 48] })
    session_joins
    spawn('rev-1', '--harness', 'claude', '--tab', 'agents')

    assert_empty herdr.splits
    assert_equal [['w1', 'agents', '/work', session_env]], herdr.created_tabs
    assert_equal 'w1:p3', herdr.starts.first[:pane]
  end

  def test_every_tab_with_the_label_is_read_and_its_pane_with_the_most_room_is_split
    workspace(%w[w1:t1 main] => { 'w1:p1' => AREA }, %w[w1:t2 agents] => { 'w1:p2' => [120, 48] },
              %w[w1:t3 agents] => { 'w1:p3' => [40, 48], 'w1:p4' => [165, 48] })
    session_joins
    spawn('rev-1', '--harness', 'claude', '--tab', 'agents')

    assert_equal %w[w1:p2 w1:p4], herdr.layouts
    assert_equal([%w[w1:p4 right]], herdr.splits.map { it.first(2) })
    assert_empty herdr.created_tabs
  end

  def test_a_layout_herdr_cannot_give_opens_a_new_tab_instead_of_splitting_a_pane_it_could_not_measure
    herdr.layout_error = 'herdr pane layout failed: unrecognized subcommand'
    session_joins
    result = spawn('rev-1', '--harness', 'claude')

    assert_equal 0, result.status, result.err
    assert_empty herdr.splits
    assert_equal [['w1', 'rev-1', '/work', session_env]], herdr.created_tabs
    assert_equal 'spawn could not read the layout of pane w1:p1: herdr pane layout failed: unrecognized subcommand; ' \
                 "it opens a new tab rather than split a pane it could not measure.\n", result.err
  end

  def test_a_layout_without_panes_opens_a_new_tab_with_the_label
    workspace(%w[w1:t1 main] => { 'w1:p1' => AREA }, %w[w1:t2 agents] => { 'w1:p2' => nil, 'w1:p3' => nil })
    session_joins
    result = spawn('rev-1', '--harness', 'claude', '--tab', 'agents', '--split', 'down')

    assert_equal 0, result.status, result.err
    assert_empty herdr.splits
    assert_equal [['w1', 'agents', '/work', session_env]], herdr.created_tabs
    assert_match(/\Aspawn could not read the layout of pane w1:p3: herdr answered without a pane layout; it opens a /,
                 result.err)
  end

  def test_one_tab_whose_layout_herdr_cannot_give_opens_a_new_tab_though_another_has_room
    workspace(%w[w1:t1 main] => { 'w1:p1' => AREA }, %w[w1:t2 agents] => { 'w1:p2' => [200, 48] },
              %w[w1:t3 agents] => { 'w1:p3' => nil })
    session_joins
    result = spawn('rev-1', '--harness', 'claude', '--tab', 'agents')

    assert_equal 0, result.status, result.err
    assert_empty herdr.splits
    assert_equal [['w1', 'agents', '/work', session_env]], herdr.created_tabs
  end
end
