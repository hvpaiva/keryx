# frozen_string_literal: true

require 'test_helper'

class WhoJSONTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def addresses = JSON.parse(keryx('who', '--all', '-o', 'json').out)['addresses'].to_h { [it['address'], it] }

  def occupant(key) = JSON.parse(File.read(tmp('state', 'addresses', key, 'occupant.json')))

  def test_a_session_gives_its_join_as_its_record_has_it_without_the_claude_socket
    join_claude('orq.dev', 111)
    join = addresses.fetch('orq.dev@athena')['join']

    assert_equal %w[cwd harness herdr_pane herdr_socket joined_at pid session_id started transcript], join.keys.sort
    assert_equal occupant('orq.dev').slice(*join.keys), join
    assert_equal ['claude', 'session-111', 111], join.values_at('harness', 'session_id', 'pid')
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{9}Z\z/, join['joined_at'])
  end

  def test_an_address_no_session_holds_has_no_join
    keryx('leave', env: join_claude('rev-1.dev', 222))

    assert_nil addresses.fetch('rev-1.dev@athena')['join']
  end

  def test_a_displaced_session_gives_its_own_join
    join_claude('rev-1.dev', 222)
    alive << 333
    keryx('join', 'rev-1.dev', '--force', env: claude(333))
    displaced = addresses.find { |address, _| address.start_with?('rev-1.dev@athena/') }.last

    assert_equal [222, 'session-222'], displaced['join'].values_at('pid', 'session_id')
    assert_equal [333, 'session-333'], addresses.fetch('rev-1.dev@athena')['join'].values_at('pid', 'session_id')
  end
end
