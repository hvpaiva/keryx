# frozen_string_literal: true

require 'test_helper'

# A session on an address from before team names spawns another such address, which the new session joins.
class FlatSpawnTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include FlatAddresses
  include SpawnHelpers

  def test_a_flat_session_spawns_a_new_flat_address_that_its_session_joins
    director = held('cp-orq', 111)
    session_joins
    result = spawn('cp-rev-2', '--harness', 'claude', 'Review PR #448', env: director)
    start = herdr.starts.first

    assert_equal [0, ''], [result.status, result.err]
    assert_match(/\ASpawned cp-rev-2@athena as a claude session in pane w1:p2, and it joined\.\n/, result.out)
    assert_equal 'cp-rev-2', start[:name]
    assert_match(/Run 'keryx join cp-rev-2', then/, start[:arguments].last)
    assert_equal(['cp-orq@athena'], store.unread('cp-rev-2').map(&:from))
    assert_equal ['cp-orq', true], [store.occupant('cp-rev-2').director, store.address('cp-rev-2').team.nil?]
  end
end
