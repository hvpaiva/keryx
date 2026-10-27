# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'rbconfig'
require_relative '../../tool/release'

# bin/release and tool/release.rb run from copies in a temporary clone of a bare origin next to it, with stub gh and gpg
# first on PATH. git takes only local paths and HTTP goes to a closed port, so no run reaches the network.
class ReleaseCloneTest < Minitest::Test
  include TempDir

  ROOT = File.expand_path('../..', __dir__)
  PULL = 'https://github.com/hvpaiva/keryx/pull/1'
  DONE = "#{PULL}\nWhen the pull request merges, run bin/release tag on main.\n".freeze
  RESUME = 'once its cause is fixed, run bin/release prepare again and it goes on from there'
  CLOSED = 'http://127.0.0.1:9'
  CHANGELOG = <<~MARKDOWN
    # Changelog

    ## [Unreleased]

    ### Added

    - Mailboxes.

    [Unreleased]: https://github.com/hvpaiva/keryx/commits/main
  MARKDOWN

  def setup
    super
    write_stubs
    git(tmp, 'init', '--quiet', '--bare', '--initial-branch=main', 'origin.git')
    stub(tmp('origin.git/hooks/pre-receive'), fails_once('push', 'pre-receive: refused on purpose'))
    FileUtils.mkdir_p([clone('bin'), clone('tool'), clone('lib/keryx'), tmp('home')])
    FileUtils.cp(File.join(ROOT, 'bin/release'), clone('bin'))
    FileUtils.cp(File.join(ROOT, 'tool/release.rb'), clone('tool'))
    File.write(clone('lib/keryx/version.rb'), "module Keryx\n  VERSION = '0.1.0'\nend\n")
    File.write(clone('CHANGELOG.md'), CHANGELOG)
    git(clone, 'init', '--quiet', '--initial-branch=main')
    git(clone, 'add', '.')
    git(clone, 'commit', '--quiet', '--message', 'start')
    git(clone, 'remote', 'add', 'origin', tmp('origin.git'))
    git(clone, 'push', '--quiet', '--set-upstream', 'origin', 'main')
  end

  def test_prepare_signs_the_release_commit_and_dates_it_in_utc
    before = Time.now.getutc.to_date.iso8601

    assert_prepared(*release('prepare'))
    assert_includes [before, Time.now.getutc.to_date.iso8601], origin_changelog[/^## \[0\.1\.0\] - (\S+)$/, 1]
    assert_match(/^gpgsig /, git(tmp('origin.git'), 'cat-file', 'commit', 'release/v0.1.0'))
  end

  def test_prepare_resumes_on_the_release_branch_after_the_commit_fails
    fail_once('gpg')
    _, err, status = release('prepare')

    assert_equal [1, "bin/release: git commit failed; #{RESUME}\n"], [status.exitstatus, err.lines.last]
    assert_equal ['release/v0.1.0', ' M CHANGELOG.md'], [git(clone, 'branch', '--show-current'), porcelain]

    assert_prepared(*release('prepare'))
    assert_equal '1', git(tmp('origin.git'), 'rev-list', '--count', 'main..release/v0.1.0')
  end

  def test_prepare_resumes_from_main_after_the_push_fails
    fail_once('push')
    _, err, status = release('prepare')

    assert_equal [1, "bin/release: git push failed; #{RESUME}\n"], [status.exitstatus, err.lines.last]
    commit = git(clone, 'rev-parse', 'release/v0.1.0')
    git(clone, 'switch', '--quiet', 'main')

    assert_prepared(*release('prepare'))
    assert_equal commit, git(tmp('origin.git'), 'rev-parse', 'release/v0.1.0')
  end

  def test_prepare_opens_the_pull_request_after_gh_fails_and_never_twice
    fail_once('gh')
    _, err, status = release('prepare')

    assert_equal [1, "bin/release: gh pr create failed; #{RESUME}\n"], [status.exitstatus, err.lines.last]
    assert_prepared(*release('prepare'))
    assert_equal "#{PULL} is open already.\n#{DONE.lines.last}", release('prepare').first
    assert_equal ['pr list', 'pr create', 'pr list', 'pr create', 'pr list'], File.readlines(tmp('gh.log'), chomp: true)
  end

  def test_the_script_names_a_missing_program
    _, err, status = release('prepare', path: tmp('stubs'))

    assert_equal [1, "bin/release: No such file or directory - git; #{RESUME}\n"], [status.exitstatus, err]
  end

  def test_the_runner_reports_output_and_success_from_the_clone
    runner = Release::Runner.new(chdir: clone)

    assert_equal [git(clone, 'rev-parse', 'HEAD'), true], runner.capture('git', 'rev-parse', 'HEAD')
    assert_equal ['', false], runner.capture('git', 'rev-parse', '--quiet', '--verify', 'refs/heads/nowhere')
    assert runner.run(tmp('stubs/gh'), 'pr', 'list')
    refute runner.run('git', 'rev-parse', '--quiet', '--verify', 'refs/heads/nowhere')
  end

  private

  def clone(*parts) = tmp('clone', *parts)

  # A run that succeeded and ended with the pull request; git's own lines come before.
  def assert_prepared(out, err, status)
    assert_predicate status, :success?, err
    assert_equal DONE.lines, out.lines.last(2)
  end

  def release(*, path: nil)
    Open3.capture3(env(path:), RbConfig.ruby, clone('bin/release'), *, chdir: clone)
  end

  def git(dir, *args)
    out, err, status = Open3.capture3(env, 'git', *args, chdir: dir)

    assert_predicate status, :success?, "git #{args.join(' ')} failed: #{err}"
    out.chomp
  end

  def porcelain = git(clone, 'status', '--porcelain')

  def origin_changelog = git(tmp('origin.git'), 'show', 'release/v0.1.0:CHANGELOG.md')

  # The zone puts the local date a day off the UTC one at any hour, so a release dated by local time shows. bin/release
  # runs outside Bundler, as a maintainer runs it, since Bundler's setup would run git itself.
  def env(path: nil)
    {
      'PATH' => path || [tmp('stubs'), ENV.fetch('PATH')].join(File::PATH_SEPARATOR),
      'HOME' => tmp('home'), 'TZ' => Time.now.getutc.hour >= 10 ? 'AAA-14' : 'AAA+12',
      'GIT_CONFIG_GLOBAL' => tmp('gitconfig'), 'GIT_CONFIG_NOSYSTEM' => '1', 'GIT_ALLOW_PROTOCOL' => 'file',
      'GIT_DIR' => nil, 'GIT_WORK_TREE' => nil, 'GIT_INDEX_FILE' => nil, 'GH_TOKEN' => nil, 'GITHUB_TOKEN' => nil,
      'HTTPS_PROXY' => CLOSED, 'https_proxy' => CLOSED, 'HTTP_PROXY' => CLOSED, 'http_proxy' => CLOSED,
      'ALL_PROXY' => CLOSED, 'all_proxy' => CLOSED, 'RUBYOPT' => nil, 'BUNDLE_GEMFILE' => nil
    }
  end

  # The git configuration signs with the stub gpg only when asked, so the commit is signed by --gpg-sign alone.
  def write_stubs
    File.write(tmp('gitconfig'), <<~INI)
      [user]
        name = Release Test
        email = release@example.invalid
      [gpg]
        program = #{tmp('stubs/gpg')}
      [commit]
        gpgsign = false
    INI
    FileUtils.mkdir_p(tmp('stubs'))
    stub(tmp('stubs/gpg'), gpg)
    stub(tmp('stubs/gh'), gh)
  end

  # gpg reads what it signs and prints a signature, and the status line git waits for on the descriptor it named.
  def gpg
    ['cat > /dev/null', *fails_once('gpg', 'gpg: signing failed: No secret key'),
     "printf '%s\\n' '-----BEGIN PGP SIGNATURE-----' '' 'c3R1Yg==' '-----END PGP SIGNATURE-----'",
     "printf '\\n[GNUPG:] SIG_CREATED D 1 8 00 0 STUB\\n' >&2"]
  end

  # gh records each subcommand, lists the pull request once one was created and creates it unless told to fail.
  def gh
    [%(echo "$1 $2" >> #{tmp('gh.log')}),
     %(if [ "$1 $2" = 'pr list' ]; then if [ -e #{tmp('pull')} ]; then cat #{tmp('pull')}; fi; exit 0; fi),
     *fails_once('gh', 'gh: not signed in'),
     "echo #{PULL} | tee #{tmp('pull')}"]
  end

  def fails_once(name, message)
    [%(if [ -e #{tmp("#{name}.fail")} ]; then rm #{tmp("#{name}.fail")}; echo '#{message}' >&2; exit 1; fi)]
  end

  def fail_once(name) = FileUtils.touch(tmp("#{name}.fail"))

  def stub(path, lines)
    File.write(path, ['#!/bin/sh', *lines, ''].join("\n"))
    File.chmod(0o755, path)
  end
end
