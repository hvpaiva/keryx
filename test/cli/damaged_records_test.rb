# frozen_string_literal: true

require 'test_helper'

class DamagedRecordsTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include PresenceHelpers

  def setup
    super
    join_claude('healthy.dev', 111)
    store.create_address('broken.dev')
    %w[broken.dev healthy.dev].each { store.deliver(it, build_message(to: "#{it}@athena")) }
  end

  def file(name) = tmp('state', 'addresses', 'broken.dev', name)

  def damage_occupant(**fields)
    File.write(file('occupant.json'), JSON.generate(build_occupant(**fields).record.merge('pid' => [])))
  end

  def overview = [keryx('who'), keryx('status'), keryx('courier', '--once')]

  def row(output, name) = output.lines.find { it.start_with?("#{name}@athena") }.split(/ {3,}/).map(&:strip)

  def assert_warned_once(runs, path)
    assert_equal [0] * runs.size, runs.map(&:status), runs.map(&:err).join
    assert_equal [1] * runs.size, runs.map { it.err.scan("warning: #{path} is damaged").size }, runs.map(&:err).join
  end

  def test_an_occupant_with_a_field_of_the_wrong_type_is_unknown_and_the_others_are_served
    damage_occupant
    who, status, courier = runs = overview

    assert_warned_once(runs, file('occupant.json'))
    assert_equal %w[broken.dev@athena - - - unknown unknown unknown 1], row(who.out, 'broken.dev')
    assert_equal %w[healthy.dev@athena - - claude live unknown unknown 1], row(who.out, 'healthy.dev')
    assert_equal %w[broken.dev@athena - unknown unknown unknown 1 0], row(status.out, 'broken.dev')
    assert_equal "rang healthy.dev@athena: rung\n", courier.out
  end

  def test_an_address_file_that_is_not_an_object_loses_only_its_role
    File.write(file('address.json'), 'true')
    who, status, courier = runs = overview

    assert_warned_once(runs, file('address.json'))
    assert_equal %w[broken.dev@athena - - - none - - 1], row(who.out, 'broken.dev')
    assert_equal %w[healthy.dev@athena - - claude live unknown unknown 1], row(who.out, 'healthy.dev')
    assert_equal %w[broken.dev@athena - none - - 1 0], row(status.out, 'broken.dev')
    assert_equal "rang healthy.dev@athena: rung\n", courier.out
  end

  def test_an_occupant_that_cannot_be_read_is_never_typed_into_its_pane
    damage_occupant(herdr_socket: SOCKET, herdr_pane: 'w1:p3')
    show('w1:p3', 'claude', 'idle', 'session-1')
    runs = [*overview, keryx('ring'), keryx('send', 'broken.dev', 'hello')]

    assert_equal [0] * runs.size, runs.map(&:status)
    assert_empty herdr.prompts
  end

  def test_ring_says_what_it_could_not_ring_and_rings_the_others
    damage_occupant(herdr_socket: SOCKET, herdr_pane: 'w1:p3')
    show('w1:p3', 'claude', 'idle', 'session-1')
    result = keryx('ring')

    assert_warned_once([result], file('occupant.json'))
    assert_equal ["broken.dev@athena   1 unread   not rung\n", "healthy.dev@athena   1 unread   rung via claude\n"],
                 result.out.lines
    assert_empty herdr.prompts
  end

  def test_join_passes_over_an_address_whose_occupant_cannot_be_read
    damage_occupant
    alive << 333
    result = keryx('join', 'impl.dev', env: claude(333))

    assert_warned_once([result], file('occupant.json'))
    assert_equal 'session-333', store.occupant('impl.dev').session_id
  end

  def test_a_spawn_record_keryx_cannot_open_is_none_and_the_join_removes_it
    skip 'root reads a file whatever its mode' if Process.uid.zero?
    File.write(file('spawned.json'), JSON.generate('director' => 'healthy.dev', 'harness' => 'claude',
                                                   'herdr_socket' => '/h.sock', 'herdr_pane' => 'w1:p2'))
    File.chmod(0, file('spawned.json'))
    alive << 333
    result = keryx('join', 'broken.dev', env: claude(333))

    assert_equal 0, result.status, result.err
    refute_path_exists file('spawned.json')
    assert_nil store.occupant('broken.dev').director
  end
end
