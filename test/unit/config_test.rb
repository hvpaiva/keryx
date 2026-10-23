# frozen_string_literal: true

require 'test_helper'

class ConfigTest < Minitest::Test
  include TempDir

  def path = tmp('config')

  def config(text)
    File.binwrite(path, text)
    Keryx::Config.new(path)
  end

  def test_a_missing_file_has_no_host_and_no_problems
    config = Keryx::Config.new(tmp('absent'))

    assert_nil config.host
    assert_empty config.problems
  end

  def test_an_empty_file_has_no_host
    assert_nil config('').host
  end

  def test_the_host_and_its_line
    host = config("# laptop\n\n  host   =  athena  \r\n").host

    assert_equal Keryx::Config::Setting.new(value: 'athena', line: 3), host
  end

  def test_comments_and_blank_lines_are_skipped_without_problems
    config = config("# host = zeus\n   # indented comment\n\t\nhost=athena\n")

    assert_equal 'athena', config.host.value
    assert_empty config.problems
  end

  def test_a_trailing_comment_is_part_of_the_value
    assert_equal 'athena # laptop', config("host = athena # laptop\n").host.value
  end

  def test_the_value_splits_at_the_first_equals_sign
    assert_equal 'a=b', config('host = a=b').host.value
  end

  def test_unknown_keys_and_malformed_lines_are_problems_and_the_rest_applies
    config = config("hots = athena\nHost = athena\nhost athena\n= athena\nhost =\nhost = zeus\n")

    assert_equal Keryx::Config::Setting.new(value: 'zeus', line: 6), config.host
    assert_equal ["#{path}:1: unknown key \"hots\", ignored", "#{path}:2: unknown key \"Host\", ignored",
                  "#{path}:3: expected key = value, ignored", "#{path}:4: expected key = value, ignored",
                  "#{path}:5: expected key = value, ignored"], config.problems
  end

  def test_a_line_that_is_not_utf8_is_a_problem
    config = config("host = \xFF\xFE\nhost = athena\n")

    assert_equal 'athena', config.host.value
    assert_equal ["#{path}:1: not valid UTF-8, ignored"], config.problems
  end

  def test_a_repeated_key_warns_and_the_last_one_wins
    config = config("host = athena\nhost = zeus\n")

    assert_equal Keryx::Config::Setting.new(value: 'zeus', line: 2), config.host
    assert_equal ["#{path}:2: host is set again, after line 1; the last one wins"], config.problems
  end

  def test_the_file_is_read_once
    config = config("host = athena\nnoise\n")
    config.host
    File.write(path, "host = zeus\n")

    assert_equal 'athena', config.host.value
    assert_equal 1, config.problems.size
  end

  def test_a_directory_cannot_be_read
    FileUtils.mkdir_p(path)

    error = assert_raises(Keryx::Error) { Keryx::Config.new(path).host }
    assert_equal "cannot read #{path}: not a regular file", error.message
  end

  def test_a_named_pipe_cannot_be_read_and_does_not_block
    File.mkfifo(path)

    error = assert_raises(Keryx::Error) { Keryx::Config.new(path).host }
    assert_equal "cannot read #{path}: not a regular file", error.message
  end

  def test_a_file_without_permission_cannot_be_read
    skip 'root reads any file' if Process.euid.zero?
    File.write(path, "host = athena\n")
    File.chmod(0o000, path)

    error = assert_raises(Keryx::Error) { Keryx::Config.new(path).host }
    assert_equal "cannot read #{path}: Permission denied", error.message
  end

  def test_a_file_under_a_file_cannot_be_read
    File.write(tmp('keryx'), '')

    error = assert_raises(Keryx::Error) { Keryx::Config.new(tmp('keryx', 'config')).host }
    assert_equal "cannot read #{tmp('keryx', 'config')}: Not a directory", error.message
  end
end
