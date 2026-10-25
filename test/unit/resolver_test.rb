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

  def test_no_match_is_an_address_from_before_team_names
    assert_equal 'rev-1@box1', resolve('rev-1', sender: 'person.local')
  end

  def test_a_current_address_from_before_team_names_comes_before_a_team_for_a_sender_with_no_team
    store.create_address('rev-1.alpha')
    store.create_address('rev-1')

    [nil, 'person.local', 'orq'].each { assert_equal 'rev-1@box1', resolve('rev-1', sender: it), it.inspect }

    assert_equal 'rev-1.beta@box1', resolve('rev-1', sender: 'orq.beta')
  end

  def test_a_retired_address_from_before_team_names_leaves_the_name_to_the_one_team_with_it
    store.create_address('rev-1.alpha')
    store.create_address('rev-1')
    store.retire('rev-1', by: 'person.local@box1', now: Time.now)

    assert_equal 'rev-1.alpha@box1', resolve('rev-1', sender: 'orq')
    store.retire('rev-1.alpha', by: 'person.local@box1', now: Time.now)

    assert_equal 'rev-1@box1', resolve('rev-1', sender: 'orq')
  end

  def test_an_address_without_a_team_is_taken_whole
    assert_equal 'hvpaiva@box1', resolve('hvpaiva@box1', sender: 'orq.alpha')
    assert_equal 'orq@zeus', resolve('orq@zeus')
  end

  def test_a_host_needs_the_full_address
    assert_raises(Keryx::Error) { resolve('rev-1.alpha@Zeus', sender: 'orq.alpha') }
    assert_raises(Keryx::Error) { resolve('Rev-1', sender: 'orq.alpha') }
  end
end
