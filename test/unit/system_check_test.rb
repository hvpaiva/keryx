# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'rbconfig'

# The suite moves the default check file to a path that never exists, so no test reads the machine's
# /etc/keryx/check, whether it builds a CheckConfig, an App or a Check itself or runs the executable.
class SystemCheckTest < Minitest::Test
  include TempDir

  LIB = File.expand_path('../../lib', __dir__)
  PROBE = "require 'keryx'; print Keryx::CheckConfig.new.path"

  def env
    { 'KERYX_HOME' => tmp('state'), 'KERYX_HOST' => 'athena', 'XDG_CONFIG_HOME' => tmp('config'),
      'HOME' => tmp('home') }
  end

  def test_the_default_check_file_in_the_suite_never_exists_and_lib_keeps_the_one_under_etc
    assert_equal SystemCheck::ABSENT, Keryx::CheckConfig.new.path
    refute_path_exists SystemCheck::ABSENT
    assert_equal '/etc/keryx/check', Keryx::CheckConfig::PATH
  end

  def test_an_app_built_without_a_check_holds_one_on_the_absent_file
    assert_equal SystemCheck::ABSENT, Keryx::App.new(env:).check.config.path
  end

  # The same -I and -r as the tests that run exe/keryx, which proves the preload they use.
  def test_ruby_run_as_the_executable_tests_run_it_sees_the_absent_file
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', LIB, '-r', SystemCheck::PRELOAD, '-e', PROBE)

    assert_predicate status, :success?, err
    assert_equal SystemCheck::ABSENT, out
  end

  def test_a_postman_or_a_receiver_built_without_a_check_raises
    postman = assert_raises(ArgumentError) do
      Keryx::Postman.new(store: nil, bell: nil, forwarder: nil, host: 'athena', clock: nil, person: 'person.local')
    end
    receiver = assert_raises(ArgumentError) do
      Keryx::Receiver.new(store: nil, bell: nil, host: 'athena', person: 'person.local')
    end

    assert_equal ['missing keyword: :check'] * 2, [postman, receiver].map(&:message)
  end
end
