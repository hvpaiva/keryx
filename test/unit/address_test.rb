# frozen_string_literal: true

require 'test_helper'

class AddressTest < Minitest::Test
  include TempDir

  def config_file(text)
    File.write(tmp('config'), text)
    Keryx::Config.new(tmp('config'))
  end

  def test_a_team_address_keeps_member_team_and_host_apart
    address = Keryx::Address.parse('rev-1.alpha@box1')

    assert_equal ['rev-1', 'alpha', 'box1', nil], address.deconstruct
    assert_equal 'rev-1.alpha', address.key
    assert_equal 'rev-1.alpha@box1', address.to_s
    assert address.local?('box1')
    refute_predicate address, :flat?
  end

  def test_a_session_address_names_one_incarnation_of_its_stable_address
    address = Keryx::Address.parse('rev-1.alpha@box1/k3m9qz')

    assert_equal 'k3m9qz', address.session
    assert_equal 'rev-1.alpha@box1/k3m9qz', address.to_s
    assert_equal 'rev-1.alpha@box1', address.stable.to_s
    assert_equal 'rev-1.alpha', address.key
  end

  def test_the_reserved_scopes_are_team_addresses_with_no_authority_of_their_own
    assert_predicate Keryx::Address.parse('ana.local@box1'), :reserved?
    assert_predicate Keryx::Address.parse('keryx.system@box1'), :reserved?
    refute_predicate Keryx::Address.parse('rev-1.alpha@box1'), :reserved?
  end

  def test_a_flat_address_from_before_team_names_still_parses
    address = Keryx::Address.parse('orq@athena')

    assert_predicate address, :flat?
    assert_equal 'orq', address.key
    assert_equal 'orq@athena', address.to_s
  end

  def test_parse_takes_only_the_full_spelling
    ['rev-1', 'rev-1.alpha', 'Rev.alpha@box1', 'rev.Alpha@box1', '1rev.alpha@box1', 'rev.1alpha@box1',
     'a.b.c@box1', 'rev.alpha@', 'rev.alpha@Box1', 'a@b@c', "r#{'e' * 32}.alpha@box1", "rev.#{'a' * 33}@box1",
     'rev.alpha@box1/', 'rev.alpha@box1/K3M9QZ', 'rev.alpha@box1/k3m9', 'rev.alpha@box1/k3m9qi', 'orq@athena/k3m9qz',
     'rev.alpha@box1/k3m9qz/x', ''].each do |text|
      assert_raises(Keryx::Error, text) { Keryx::Address.parse(text) }
    end
  end

  def test_each_segment_holds_up_to_32_characters
    member = "r#{'e' * 31}"
    team = "a#{'l' * 31}"

    assert_equal "#{member}.#{team}", Keryx::Address.parse("#{member}.#{team}@box1").key
  end

  def test_key_tells_a_store_directory_name_from_anything_else
    %w[rev-1.alpha orq ana.local].each { assert Keryx::Address.key?(it), "#{it} is a store name" }
    ['Rev.alpha', 'a.b.c', 'rev-1.', '.alpha', 'rev-1@box1', '', nil].each { refute Keryx::Address.key?(it), it.inspect }
  end

  def test_name_tells_a_key_or_an_incarnation_of_a_team_address_from_anything_else
    %w[rev-1.alpha orq rev-1.alpha/k3m9qz].each { assert Keryx::Address.name?(it), "#{it} is a name" }

    ['orq/k3m9qz', 'rev-1.alpha/K3M9QZ', 'rev-1.alpha/k3m9q', 'rev-1.alpha/', 'Orq@x', '', nil].each do |text|
      refute Keryx::Address.name?(text), text.inspect
    end
  end

  def test_a_store_key_and_a_host_make_the_address
    assert_equal 'rev-1.alpha@box1', Keryx::Address.from_key('rev-1.alpha', host: 'box1').to_s
    assert_equal 'orq@box1', Keryx::Address.from_key('orq', host: 'box1').to_s
    assert_raises(Keryx::Error) { Keryx::Address.from_key('a.b.c', host: 'box1') }
  end

  def test_local_host_prefers_keryx_host
    assert_equal 'athena', Keryx::Address.local_host({ 'KERYX_HOST' => 'athena' }, hostname: 'LAP-0042')
  end

  def test_local_host_rejects_an_invalid_keryx_host
    error = assert_raises(Keryx::Error) { Keryx::Address.local_host({ 'KERYX_HOST' => 'Athena' }) }
    assert_equal 'KERYX_HOST "Athena" is not a valid host name', error.message
  end

  def test_local_host_prefers_keryx_host_over_the_config_file
    config = config_file("host = zeus\n")

    assert_equal 'athena', Keryx::Address.local_host({ 'KERYX_HOST' => 'athena' }, config:, hostname: 'lap-0042')
  end

  def test_local_host_takes_the_config_file_over_the_machine_name
    config = config_file("host = athena\n")

    assert_equal 'athena', Keryx::Address.local_host({}, config:, hostname: 'LAP-0042')
    assert_equal 'athena', Keryx::Address.local_host({ 'KERYX_HOST' => '' }, config:, hostname: 'LAP-0042')
  end

  def test_local_host_falls_back_to_the_machine_name_without_a_host_in_the_file
    assert_equal 'lap-0042', Keryx::Address.local_host({}, config: config_file("# none\n"), hostname: 'LAP-0042')
  end

  def test_local_host_rejects_an_invalid_host_in_the_config_file_with_its_line
    config = config_file("host = athena\nhost = Athena\n")

    error = assert_raises(Keryx::Error) { Keryx::Address.local_host({}, config:, hostname: 'lap-0042') }
    assert_equal "#{config.path}:2: host \"Athena\" is not a valid host name", error.message
  end

  def test_local_host_reads_no_config_file_when_keryx_host_is_set
    config = Keryx::Config.new(tmp('unreadable'))
    FileUtils.mkdir_p(config.path)

    assert_equal 'athena', Keryx::Address.local_host({ 'KERYX_HOST' => 'athena' }, config:)
  end

  def test_local_host_derives_a_valid_label_from_the_machine_name
    assert_equal 'lap-0042', Keryx::Address.local_host({}, hostname: 'LAP-0042.corp.example')
    assert_equal 'my-mac', Keryx::Address.local_host({}, hostname: 'My_Mac')
    assert_equal 'localhost', Keryx::Address.local_host({}, hostname: '')
  end

  def test_a_name_with_a_session_reads_as_that_incarnation_and_prints_back
    address = Keryx::Address.from_name('rev-1.dev/k3m9qz', host: 'athena')

    assert_equal ['rev-1.dev@athena/k3m9qz', 'rev-1.dev/k3m9qz', 'rev-1.dev'],
                 [address.to_s, address.name, Keryx::Address.from_name('rev-1.dev', host: 'athena').name]
    assert_raises(Keryx::Error) { Keryx::Address.from_name('rev-1.dev/K3M9QZ', host: 'athena') }
    assert_raises(Keryx::Error) { Keryx::Address.from_name('rev-1/k3m9qz', host: 'athena') }
  end

  def test_a_drawn_session_is_in_the_alphabet_and_never_one_already_bound
    draws = Array.new(6, 0) + Array.new(6, 1)
    random = Object.new.tap { it.define_singleton_method(:random_number) { |_limit| draws.shift } }

    assert_equal '111111', Keryx::Address.draw_session(['000000'], random:)
    assert_match Keryx::Address::SESSION, Keryx::Address.draw_session
  end
end
