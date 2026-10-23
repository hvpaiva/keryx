# frozen_string_literal: true

require 'test_helper'

class AddressTest < Minitest::Test
  include TempDir

  def config_file(text)
    File.write(tmp('config'), text)
    Keryx::Config.new(tmp('config'))
  end

  def test_a_bare_name_is_on_the_local_host
    address = Keryx::Address.parse('rev-1', local_host: 'athena')

    assert_equal 'rev-1@athena', address.to_s
    assert address.local?('athena')
  end

  def test_a_full_address_keeps_its_host
    address = Keryx::Address.parse('port@zeus', local_host: 'athena')

    assert_equal 'zeus', address.host
    refute address.local?('athena')
  end

  def test_parse_rejects_bad_names_hosts_and_extra_at_signs
    ['Rev', '1rev', '', 'a@b@c', 'rev@', 'rev@Zeus', "r#{'e' * 32}"].each do |text|
      assert_raises(Keryx::Error, text) { Keryx::Address.parse(text, local_host: 'athena') }
    end
  end

  def test_local_host_prefers_keryx_host
    assert_equal 'athena', Keryx::Address.local_host({ 'KERYX_HOST' => 'athena' }, hostname: 'RD-008575')
  end

  def test_local_host_rejects_an_invalid_keryx_host
    error = assert_raises(Keryx::Error) { Keryx::Address.local_host({ 'KERYX_HOST' => 'Athena' }) }
    assert_equal 'KERYX_HOST "Athena" is not a valid host name', error.message
  end

  def test_local_host_prefers_keryx_host_over_the_config_file
    config = config_file("host = zeus\n")

    assert_equal 'athena', Keryx::Address.local_host({ 'KERYX_HOST' => 'athena' }, config:, hostname: 'rd-008575')
  end

  def test_local_host_takes_the_config_file_over_the_machine_name
    config = config_file("host = athena\n")

    assert_equal 'athena', Keryx::Address.local_host({}, config:, hostname: 'RD-008575')
    assert_equal 'athena', Keryx::Address.local_host({ 'KERYX_HOST' => '' }, config:, hostname: 'RD-008575')
  end

  def test_local_host_falls_back_to_the_machine_name_without_a_host_in_the_file
    assert_equal 'rd-008575', Keryx::Address.local_host({}, config: config_file("# none\n"), hostname: 'RD-008575')
  end

  def test_local_host_rejects_an_invalid_host_in_the_config_file_with_its_line
    config = config_file("host = athena\nhost = Athena\n")

    error = assert_raises(Keryx::Error) { Keryx::Address.local_host({}, config:, hostname: 'rd-008575') }
    assert_equal "#{config.path}:2: host \"Athena\" is not a valid host name", error.message
  end

  def test_local_host_reads_no_config_file_when_keryx_host_is_set
    config = Keryx::Config.new(tmp('unreadable'))
    FileUtils.mkdir_p(config.path)

    assert_equal 'athena', Keryx::Address.local_host({ 'KERYX_HOST' => 'athena' }, config:)
  end

  def test_local_host_derives_a_valid_label_from_the_machine_name
    assert_equal 'rd-008575', Keryx::Address.local_host({}, hostname: 'RD-008575.corp.example')
    assert_equal 'my-mac', Keryx::Address.local_host({}, hostname: 'My_Mac')
    assert_equal 'localhost', Keryx::Address.local_host({}, hostname: '')
  end
end
