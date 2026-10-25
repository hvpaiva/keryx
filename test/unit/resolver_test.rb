# frozen_string_literal: true

require 'test_helper'

class ResolverTest < Minitest::Test
  include TempDir

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def resolver = Keryx::Resolver.new(store:, host: 'box1')

  def resolve(text, sender: nil, **) = resolver.resolve(text, sender:, **).to_s

  def test_a_bare_member_is_that_member_of_the_senders_team_with_no_fallback
    store.create_address('rev-1.beta')

    assert_equal 'rev-1.alpha@box1', resolve('rev-1', sender: 'orq.alpha')
  end

  def test_a_member_and_team_stay_on_this_host
    assert_equal 'rev-1.beta@box1', resolve('rev-1.beta', sender: 'orq.alpha')
  end

  def test_a_full_address_is_taken_as_written
    assert_equal 'port.ports@zeus', resolve('port.ports@zeus', sender: 'orq.alpha')
  end

  def test_a_session_follows_any_form
    assert_equal 'rev-1.alpha@box1/k3m9qz', resolve('rev-1/k3m9qz', sender: 'orq.alpha')
    assert_equal 'rev-1.beta@box1/k3m9qz', resolve('rev-1.beta/k3m9qz', sender: 'orq.alpha')
    assert_equal 'rev-1.beta@zeus/k3m9qz', resolve('rev-1.beta@zeus/k3m9qz', sender: 'orq.alpha')
    assert_raises(Keryx::Error) { resolve('rev-1/K3M9QZ', sender: 'orq.alpha') }
  end

  def test_a_bare_member_from_a_sender_with_no_team_needs_exactly_one_match
    store.create_address('rev-1.alpha')
    store.create_address('orq.beta')

    [nil, 'person.local', 'keryx.system'].each do |sender|
      assert_equal 'rev-1.alpha@box1', resolve('rev-1', sender:), sender.inspect
    end
  end

  def test_several_matches_are_an_error_that_lists_them
    store.create_address('rev-1.alpha')
    store.create_address('rev-1.beta')

    error = assert_raises(Keryx::Error) { resolve('rev-1', sender: 'person.local') }
    assert_equal 'rev-1 matches rev-1.alpha@box1 and rev-1.beta@box1; name the team, as rev-1.alpha', error.message
  end

  def test_no_match_says_how_to_name_the_team
    error = assert_raises(Keryx::Error) { resolve('rev-1', sender: 'person.local') }
    assert_equal 'no address rev-1.TEAM on box1; name the team, as rev-1.TEAM', error.message
  end

  def test_a_retired_address_and_one_from_before_team_names_are_no_match
    store.create_address('rev-1.alpha')
    store.retire('rev-1.alpha', by: 'person.local@box1', now: Time.now)
    FileUtils.mkdir_p(tmp('state', 'addresses', 'rev-1'))
    File.write(tmp('state', 'addresses', 'rev-1', 'address.json'),
               '{"name":"rev-1","created_at":"2026-10-23T00:00:00Z"}')

    assert_raises(Keryx::Error) { resolve('rev-1', sender: 'person.local') }
  end

  def test_an_address_without_a_team_is_refused_with_the_spelling_to_use
    error = assert_raises(Keryx::Error) { resolve('hvpaiva@box1', sender: 'orq.alpha') }
    assert_equal 'hvpaiva@box1 has no team: an address is MEMBER.TEAM@HOST, such as hvpaiva.TEAM@box1, and a ' \
                 'person at a terminal is hvpaiva.local@box1', error.message
  end

  def test_an_address_without_a_team_is_taken_where_the_caller_allows_it
    assert_equal 'orq@box1', resolve('orq@box1', flat: true)
    assert_raises(Keryx::Error) { resolve('orq', flat: true) }
  end

  def test_a_host_needs_the_full_address
    assert_raises(Keryx::Error) { resolve('rev-1@zeus', sender: 'orq.alpha') }
    assert_raises(Keryx::Error) { resolve('Rev-1', sender: 'orq.alpha') }
  end
end
