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

  def direct(key, director)
    path = tmp('state', 'addresses', key, 'occupant.json')
    File.write(path, JSON.generate(JSON.parse(File.read(path)).merge('director' => director)))
  end

  def directors = addresses.transform_values { it['director'] }

  def test_a_session_gives_the_director_spawn_recorded_and_the_text_view_shows_it
    join_claude('orq.dev', 111)
    join_claude('impl.dev', 222)
    join_claude('rev-1.dev', 333)
    direct('impl.dev', 'orq.dev')
    direct('rev-1.dev', 'orq.dev/abcdef')
    rows = keryx('who').out.lines.map(&:split).to_h { [it[0], it[2]] }

    assert_equal({ 'orq.dev@athena' => nil, 'impl.dev@athena' => 'orq.dev@athena',
                   'rev-1.dev@athena' => 'orq.dev@athena/abcdef' }, directors.except('person.local@athena'))
    assert_equal %w[- orq.dev@athena], rows.values_at('orq.dev@athena', 'impl.dev@athena')
  end

  def test_a_director_that_is_the_session_s_own_address_or_retired_here_is_none
    join_claude('orq.dev', 111)
    join_claude('impl.dev', 222)
    Keryx::Store.new(tmp('state')).create_address('gone.dev')
    direct('orq.dev', 'orq.dev/abcdef')
    direct('impl.dev', 'gone.dev')
    Keryx::Store.new(tmp('state')).retire('gone.dev', by: 'person.local', now: NOW)

    assert_equal [nil, nil], directors.values_at('orq.dev@athena', 'impl.dev@athena')
  end
end
