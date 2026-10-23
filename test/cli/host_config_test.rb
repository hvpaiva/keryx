# frozen_string_literal: true

require 'test_helper'

class HostConfigTest < Minitest::Test
  include TempDir
  include CLIHelpers

  def config_path = tmp('config', 'keryx', 'config')

  def whoami(env = { 'KERYX_HOST' => '' }) = keryx('whoami', '-o', 'json', env:)

  def test_the_config_file_names_the_machine_when_keryx_host_is_unset
    write_config("host = zeus\n")
    result = whoami

    assert_equal 0, result.status
    assert_equal 'person@zeus', JSON.parse(result.out)['address']
    assert_empty result.err
  end

  def test_keryx_host_wins_and_the_file_is_not_read
    write_config("host = zeus\nnoise\n")
    result = whoami({})

    assert_equal 'person@athena', JSON.parse(result.out)['address']
    assert_empty result.err
  end

  def test_a_line_keryx_cannot_use_is_a_warning_once_and_the_command_goes_on
    write_config("hots = zeus\nhost = zeus\n")
    result = whoami

    assert_equal 0, result.status
    assert_equal 'person@zeus', JSON.parse(result.out)['address']
    assert_equal "warning: #{config_path}:1: unknown key \"hots\", ignored\n", result.err
  end

  def test_an_invalid_host_in_the_file_is_an_error_naming_the_file_and_line
    write_config("host = zeus\nhost = Zeus\n")
    result = whoami

    assert_equal 1, result.status
    assert_empty result.out
    assert_equal "error: #{config_path}:2: host \"Zeus\" is not a valid host name\n" \
                 "warning: #{config_path}:2: host is set again, after line 1; the last one wins\n", result.err
  end

  def test_a_config_file_keryx_cannot_read_is_an_error
    FileUtils.mkdir_p(config_path)
    result = whoami

    assert_equal 1, result.status
    assert_equal "error: cannot read #{config_path}: not a regular file\n", result.err
  end

  def test_the_courier_warns_about_the_config_before_its_first_wait
    write_config("hots = zeus\nhost = zeus\n")
    err = StringIO.new
    terminal = Keryx::CLI::Terminal.new(out: StringIO.new, err:, env: base_env.merge('KERYX_HOST' => ''))
    seen = nil
    sleeper = lambda do |_seconds|
      seen = err.string.dup
      raise Interrupt
    end
    factory = lambda do |_globals|
      Keryx::App.new(env: terminal.env, herdr:, remote:, clock:, claude_socket: sockets, codex:, sleeper:,
                     processes:)
    end

    assert_equal 130, Keryx.run(%w[courier], terminal:, app_factory: factory)
    assert_equal "warning: #{config_path}:1: unknown key \"hots\", ignored\n", seen
    assert_equal "#{seen}\n", err.string
  end

  def test_a_warning_printed_early_is_not_printed_again_at_the_end
    write_config("hots = zeus\nhost = zeus\n")

    assert_equal "warning: #{config_path}:1: unknown key \"hots\", ignored\n",
                 keryx('courier', '--once', env: { 'KERYX_HOST' => '' }).err
  end

  def test_without_a_file_or_keryx_host_the_machine_name_is_used
    expected = Keryx::Address.local_host({})

    assert_equal "person@#{expected}", JSON.parse(whoami.out)['address']
  end
end
