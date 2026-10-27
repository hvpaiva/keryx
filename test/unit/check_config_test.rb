# frozen_string_literal: true

require 'test_helper'

# The machine's umask may make new files group-writable, so every file and folder here gets its mode explicitly. The
# paths start at the real path of the temporary folder, since the walk refuses a link on the way, as /tmp is on macOS.
class CheckConfigTest < Minitest::Test
  include TempDir

  TRUSTED = ->(stat) { [0, Process.uid].include?(stat.uid) }

  def setup
    super
    @real = File.realpath(tmp)
  end

  def real(*parts) = File.join(@real, *parts)

  def path = real('check')

  def write(name, text, mode: 0o644)
    File.binwrite(name, text)
    File.chmod(mode, name)
    name
  end

  def folder(name, mode: 0o755)
    Dir.mkdir(name)
    File.chmod(mode, name)
    name
  end

  def stub(name = real('checker'), mode: 0o755) = write(name, "#!/bin/sh\nexit 0\n", mode:)

  def config(text, at: path, trusted: TRUSTED)
    write(at, text)
    Keryx::CheckConfig.new(path: at, trusted:)
  end

  def checking(command, trusted: TRUSTED) = config("command = #{command}\n", trusted:)

  def broken(config) = assert_raises(Keryx::CheckConfig::Broken) { config.setup }.message

  def setup_of(command, timeout = 5) = Keryx::CheckConfig::Setup.new(command:, timeout:)

  # Root's, as the default predicate has it, and besides only the files and folders named, by inode.
  def root_or(*names)
    own = names.map { File.stat(it).then { |stat| [stat.dev, stat.ino] } }
    ->(stat) { Keryx::CheckConfig::ROOT.call(stat) || own.include?([stat.dev, stat.ino]) }
  end

  def test_no_file_means_no_check
    assert_nil Keryx::CheckConfig.new(path: real('absent'), trusted: TRUSTED).setup
  end

  def test_a_valid_file_gives_the_checker_and_its_timeout
    config = config("# the checker\n\n  command  =  #{stub}  \ntimeout = 12\n")

    assert_equal setup_of(real('checker'), 12), config.setup
  end

  def test_the_timeout_is_five_seconds_by_default
    assert_equal setup_of(stub, Keryx::CheckConfig::DEFAULT_TIMEOUT), checking(stub).setup
    assert_equal 5, Keryx::CheckConfig::DEFAULT_TIMEOUT
  end

  def test_the_file_as_a_symbolic_link_is_refused
    write(real('elsewhere'), "command = #{stub}\n")
    File.symlink(real('elsewhere'), path)

    assert_equal "#{path} is a symbolic link; keryx honors only a regular file",
                 broken(Keryx::CheckConfig.new(path:, trusted: TRUSTED))
  end

  def test_a_directory_is_refused
    folder(path)

    assert_equal "#{path} is not a regular file", broken(Keryx::CheckConfig.new(path:, trusted: TRUSTED))
  end

  def test_a_file_the_default_predicate_finds_not_owned_by_root_is_refused
    skip 'the test user is root' if Process.uid.zero?
    write(path, "command = #{stub}\n")

    assert_equal "#{path} is not owned by root", broken(Keryx::CheckConfig.new(path:))
  end

  def test_a_file_writable_by_its_group_is_refused
    config = checking(stub)
    File.chmod(0o664, path)

    assert_equal "#{path} is writable by group or others", broken(config)
  end

  def test_a_file_writable_by_others_is_refused
    config = checking(stub)
    File.chmod(0o646, path)

    assert_equal "#{path} is writable by group or others", broken(config)
  end

  def test_a_folder_above_the_file_writable_by_others_is_refused
    config = config("command = #{stub}\n", at: File.join(folder(real('open'), mode: 0o777), 'check'))

    assert_equal "#{real('open')} is writable by group or others, so the file in it could be replaced", broken(config)
  end

  def test_a_sticky_folder_above_the_file_writable_by_others_passes
    config = config("command = #{stub}\n", at: File.join(folder(real('shared'), mode: 0o1777), 'check'))

    assert_equal setup_of(real('checker')), config.setup
  end

  def test_a_folder_above_the_file_that_is_a_symbolic_link_is_refused
    checking(stub)
    File.symlink(@real, real('link'))
    config = Keryx::CheckConfig.new(path: real('link', 'check'), trusted: TRUSTED)

    assert_equal "#{real('link')} is a symbolic link; name the file under its real path", broken(config)
  end

  def test_a_file_this_user_cannot_read_is_refused
    skip 'root reads any file' if Process.uid.zero?
    config = checking(stub)
    File.chmod(0o000, path)

    assert_equal "cannot read #{path}: Permission denied", broken(config)
  end

  def test_a_file_without_a_command_is_refused
    assert_equal "#{path} names no command", broken(config("# nothing yet\ntimeout = 5\n"))
  end

  def test_a_relative_command_is_refused
    assert_equal "#{path}:2: command must be an absolute path, not \"nomos check\"",
                 broken(config("# the checker\ncommand = nomos check\n"))
  end

  def test_an_unknown_key_is_refused
    assert_equal "#{path}:2: unknown key \"comand\"", broken(config("timeout = 5\ncomand = #{stub}\n"))
  end

  def test_a_key_set_twice_is_refused
    assert_equal "#{path}:3: command is set again, after line 1",
                 broken(config("command = #{stub}\ntimeout = 5\ncommand = #{stub}\n"))
  end

  def test_a_line_without_an_equals_sign_is_refused
    assert_equal "#{path}:2: expected key = value", broken(config("command = #{stub}\ntimeout 5\n"))
  end

  def test_a_file_that_is_not_utf8_is_refused
    assert_equal "#{path}: not valid UTF-8", broken(config("command = #{stub}\n# caf\xE9\n"))
  end

  def test_a_timeout_outside_one_to_thirty_whole_seconds_is_refused
    %w[0 31 5s].each do |value|
      assert_equal "#{path}:2: timeout must be a whole number of seconds from 1 to 30, not \"#{value}\"",
                   broken(config("command = #{stub}\ntimeout = #{value}\n"))
    end
  end

  def test_a_missing_checker_is_refused
    assert_equal "the checker #{real('absent')} does not exist", broken(checking(real('absent')))
  end

  def test_a_checker_that_is_a_symbolic_link_is_refused
    File.symlink(stub, real('linked'))

    assert_equal "the checker #{real('linked')} is a symbolic link; name the file itself",
                 broken(checking(real('linked')))
  end

  def test_a_checker_that_is_a_directory_is_refused
    assert_equal "the checker #{real('bin')} is not a regular file", broken(checking(folder(real('bin'))))
  end

  def test_a_checker_the_predicate_does_not_trust_is_refused
    checker = File.stat(stub)
    trusted = ->(stat) { [stat.dev, stat.ino] != [checker.dev, checker.ino] && TRUSTED.call(stat) }

    assert_equal "the checker #{real('checker')} is not owned by root",
                 broken(checking(real('checker'), trusted:))
  end

  def test_a_checker_writable_by_its_group_is_refused
    assert_equal "the checker #{real('checker')} is writable by group or others",
                 broken(checking(stub(mode: 0o775)))
  end

  def test_a_checker_that_is_not_executable_is_refused
    assert_equal "the checker #{real('checker')} is not executable", broken(checking(stub(mode: 0o644)))
  end

  # Ruby would hand such a file to /bin/sh, so a text without #! or an empty file is refused before anything runs.
  def test_a_checker_that_starts_neither_as_a_script_nor_as_a_binary_is_refused
    ["exit 0\n", ''].each do |text|
      write(real('checker'), text, mode: 0o755)

      assert_equal "the checker #{real('checker')} starts with neither #! nor an ELF or Mach-O header",
                   broken(checking(real('checker')))
    end
  end

  # The header alone, since the check reads no further.
  def test_a_checker_that_starts_with_an_elf_or_mach_o_header_passes
    ["\x7FELF", "\xFE\xED\xFA\xCE", "\xFE\xED\xFA\xCF", "\xCE\xFA\xED\xFE", "\xCF\xFA\xED\xFE",
     "\xCA\xFE\xBA\xBE"].each do |header|
      write(real('checker'), header.b, mode: 0o755)

      assert_equal setup_of(real('checker')), checking(real('checker')).setup
    end
  end

  # Mode 0111 leaves its owner what a root checker of mode 0711 leaves every other user: running it, not reading it.
  def test_a_checker_this_user_can_run_but_not_read_is_refused
    skip 'root reads any file' if Process.uid.zero?

    assert_equal "cannot read the checker #{real('checker')}: Permission denied",
                 broken(checking(stub(mode: 0o111)))
  end

  def test_a_checker_in_a_folder_its_group_can_write_is_refused
    checker = stub(File.join(folder(real('shared'), mode: 0o775), 'checker'))

    assert_equal "#{real('shared')} is writable by group or others, so the file in it could be replaced",
                 broken(checking(checker))
  end

  def test_a_checker_named_through_a_folder_that_is_a_symbolic_link_is_refused
    stub
    File.symlink(@real, real('link'))

    assert_equal "#{real('link')} is a symbolic link; name the file under its real path",
                 broken(checking(real('link', 'checker')))
  end

  # The file is the test user's, so only its inode and its folder's count as root's; the checker and every folder
  # above it pass the default predicate on their own. Where coreutils is a multicall binary /usr/bin/true may be a
  # link, which the check refuses, so the checker is named by its real path.
  def test_a_system_checker_passes_the_default_predicate_and_the_real_walk
    command = File.realpath('/usr/bin/true')
    write(path, "command = #{command}\n")

    assert_equal setup_of(command), Keryx::CheckConfig.new(path:, trusted: root_or(path, @real)).setup
  end

  def test_a_system_checker_named_through_its_link_is_refused
    skip '/usr/bin/true is the file itself here' unless File.symlink?('/usr/bin/true')
    write(path, "command = /usr/bin/true\n")

    assert_equal 'the checker /usr/bin/true is a symbolic link; name the file itself',
                 broken(Keryx::CheckConfig.new(path:, trusted: root_or(path, @real)))
  end
end
