# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'rbconfig'
require_relative '../../tool/release'

class ReleaseTest < Minitest::Test
  include TempDir

  BIN = File.expand_path('../../bin/release', __dir__)
  TODAY = Date.new(2026, 10, 23)
  REPOSITORY = 'https://github.com/hvpaiva/keryx'
  UNRELEASED = <<~MARKDOWN.freeze
    # Changelog

    ## [Unreleased]

    ### Added

    - Mailboxes.

    [Unreleased]: #{REPOSITORY}/commits/main
  MARKDOWN
  RELEASED = <<~MARKDOWN.freeze
    # Changelog

    ## [Unreleased]

    ## [0.1.0] - 2026-10-23

    ### Added

    - Mailboxes.

    [Unreleased]: #{REPOSITORY}/compare/v0.1.0...HEAD
    [0.1.0]: #{REPOSITORY}/releases/tag/v0.1.0
  MARKDOWN

  RESUME = 'once its cause is fixed, run bin/release prepare again and it goes on from there'
  ON_BRANCH = { %w[git branch --show-current] => ['release/v0.1.0', true] }.freeze
  COMMITTED = ON_BRANCH.merge(%w[git rev-list --count origin/main..HEAD] => ['1', true],
                              %w[git diff --name-only origin/main HEAD] => ['CHANGELOG.md', true]).freeze
  BRANCH_ON_ORIGIN = %w[git ls-remote origin refs/heads/release/v0.1.0].freeze
  PUSHED = COMMITTED.merge(BRANCH_ON_ORIGIN => ["abc\trefs/heads/release/v0.1.0", true]).freeze
  OPEN_PULL = %w[gh pr list --head release/v0.1.0 --state open --json url --jq .[].url].freeze
  WRITES = [%w[git switch], %w[git commit], %w[git push], %w[gh pr create]].freeze

  # Answers each captured command from ANSWERS, or with empty output and success, and fails the one command that
  # starts with FAILING. MAIN is the CHANGELOG.md of origin/main.
  class FakeRunner
    attr_reader :answers, :commands

    def initialize(answers = {}, failing: nil, main: UNRELEASED)
      @answers = {
        %w[git branch --show-current] => ['main', true],
        %w[git rev-parse HEAD] => ['abc', true],
        %w[git rev-parse origin/main] => ['abc', true],
        %w[git rev-parse --quiet --verify refs/tags/v0.1.0] => ['', false],
        %w[git rev-parse --quiet --verify refs/heads/release/v0.1.0] => ['', false],
        %w[git rev-list --count HEAD..origin/main] => ['0', true],
        %w[git rev-list --count origin/main..HEAD] => ['0', true],
        %w[git show origin/main:CHANGELOG.md] => [main, true]
      }.merge(answers)
      @failing = failing
      @commands = []
    end

    def capture(*argv)
      @commands << argv
      return ['', false] if failing?(argv)

      answer = @answers.fetch(argv, ['', true])
      answer.respond_to?(:call) ? answer.call : answer
    end

    def run(*argv)
      @commands << argv
      argv unless failing?(argv)
    end

    private

    def failing?(argv) = !@failing.nil? && argv.first(@failing.size) == @failing
  end

  # A clone whose CHANGELOG.md holds CHANGELOG and whose HEAD holds HEAD; git status tells them apart unless the test
  # answers it.
  def release(runner = FakeRunner.new, changelog: UNRELEASED, head: changelog)
    FileUtils.mkdir_p(tmp('lib/keryx'))
    File.write(tmp('lib/keryx/version.rb'), "module Keryx\n  VERSION = '0.1.0'\nend\n")
    File.write(tmp('CHANGELOG.md'), changelog)
    runner.answers[%w[git status --porcelain]] ||= -> { [changes(head), true] }
    @out = StringIO.new
    Release.new(root: tmp, runner:, out: @out, today: TODAY)
  end

  def changes(head) = File.read(tmp('CHANGELOG.md')) == head ? '' : ' M CHANGELOG.md'

  def writes(runner) = runner.commands.select { |argv| WRITES.any? { argv.first(it.size) == it } }

  def test_cut_dates_the_unreleased_changes_and_links_the_tag
    assert_equal RELEASED, Release::Changelog.cut(UNRELEASED, '0.1.0', '2026-10-23')
  end

  def test_cut_refuses_a_changelog_with_nothing_to_release
    empty = UNRELEASED.sub("### Added\n\n- Mailboxes.\n\n", '')
    error = assert_raises(Release::Error) { Release::Changelog.cut(empty, '0.1.0', '2026-10-23') }

    assert_equal 'CHANGELOG.md has nothing under ## [Unreleased] to release', error.message
  end

  def test_cut_refuses_a_changelog_without_the_unreleased_section_or_link
    without_section = UNRELEASED.sub('## [Unreleased]', '## Unreleased')
    without_link = UNRELEASED.sub(/^\[Unreleased\]: .*\n/, '')

    assert_raises(Release::Error) { Release::Changelog.cut(without_section, '0.1.0', '2026-10-23') }
    assert_raises(Release::Error) { Release::Changelog.cut(without_link, '0.1.0', '2026-10-23') }
  end

  def test_notes_are_the_body_of_the_version_section
    assert_equal "### Added\n\n- Mailboxes.", Release::Changelog.notes(RELEASED, '0.1.0')
    assert_raises(Release::Error) { Release::Changelog.notes(UNRELEASED, '0.1.0') }
  end

  def test_a_link_definition_inside_a_section_stays_in_it
    body = "### Security\n\n- A [fixed advisory][advisory].\n\n[advisory]: https://example.com/advisory"
    cut = Release::Changelog.cut(UNRELEASED.sub("### Added\n\n- Mailboxes.", body), '0.1.0', '2026-10-23')

    assert_equal body, Release::Changelog.notes(cut, '0.1.0')
  end

  def test_prepare_opens_a_pull_request_that_dates_the_changelog
    runner = FakeRunner.new
    release(runner).prepare
    title = 'chore: release 0.1.0'

    assert_equal RELEASED, File.read(tmp('CHANGELOG.md'))
    assert_equal [%w[git switch --create release/v0.1.0],
                  ['git', 'commit', '--gpg-sign', '--message', title, '--', 'CHANGELOG.md'],
                  %w[git push --set-upstream origin release/v0.1.0]], writes(runner)[0..2]
    assert_equal ['gh', 'pr', 'create', '--base', 'main', '--head', 'release/v0.1.0', '--title', title],
                 writes(runner).last.first(9)
    assert_includes writes(runner).last.last, "### Added\n\n- Mailboxes."
    assert_equal "When the pull request merges, run bin/release tag on main.\n", @out.string
  end

  def test_prepare_names_a_failed_commit_and_then_commits_the_dated_changelog
    failed = FakeRunner.new(failing: %w[git commit])
    error = assert_raises(Release::Error) { release(failed).prepare }

    assert_equal "git commit failed; #{RESUME}", error.message
    assert_equal RELEASED, File.read(tmp('CHANGELOG.md'))

    resumed = FakeRunner.new(ON_BRANCH)
    release(resumed, changelog: RELEASED, head: UNRELEASED).prepare

    assert_equal([%w[git commit], %w[git push], %w[gh pr]], writes(resumed).map { it.first(2) })
    assert_equal RELEASED, File.read(tmp('CHANGELOG.md'))
  end

  def test_prepare_names_a_failed_push_and_then_pushes_the_release_commit
    failed = FakeRunner.new(failing: %w[git push])
    error = assert_raises(Release::Error) { release(failed).prepare }

    assert_equal "git push failed; #{RESUME}", error.message
    refute(writes(failed).any? { it.first(2) == %w[gh pr] })

    resumed = FakeRunner.new(COMMITTED)
    release(resumed, changelog: RELEASED).prepare

    assert_equal [%w[git push --set-upstream origin release/v0.1.0]], writes(resumed).first(1)
    assert_equal([%w[git push], %w[gh pr]], writes(resumed).map { it.first(2) })
  end

  def test_prepare_names_a_failed_pull_request_without_its_body_and_then_opens_it
    failed = FakeRunner.new(failing: %w[gh pr create])
    error = assert_raises(Release::Error) { release(failed).prepare }

    assert_equal "gh pr create failed; #{RESUME}", error.message

    resumed = FakeRunner.new(PUSHED)
    release(resumed, changelog: RELEASED).prepare

    assert_equal([%w[gh pr create]], writes(resumed).map { it.first(3) })
    assert_equal "When the pull request merges, run bin/release tag on main.\n", @out.string
  end

  def test_prepare_on_main_takes_up_the_release_branch_an_earlier_run_left
    left = COMMITTED.merge(%w[git branch --show-current] => ['main', true],
                           %w[git rev-parse --quiet --verify refs/heads/release/v0.1.0] => ['def', true])
    runner = FakeRunner.new(left)
    release(runner, changelog: RELEASED).prepare

    assert_equal [%w[git switch release/v0.1.0], %w[git push --set-upstream origin release/v0.1.0]],
                 writes(runner).first(2)
    assert_equal %w[gh pr create], writes(runner).last.first(3)
  end

  def test_prepare_dates_the_changelog_again_on_a_release_branch_without_it
    runner = FakeRunner.new(ON_BRANCH)
    release(runner).prepare

    assert_equal RELEASED, File.read(tmp('CHANGELOG.md'))
    assert_equal([%w[git commit], %w[git push], %w[gh pr]], writes(runner).map { it.first(2) })
  end

  def test_prepare_words_a_detached_head_a_failed_query_and_a_missing_version
    detached = FakeRunner.new({ %w[git branch --show-current] => ['', true] })

    assert_equal 'run bin/release on main or release/v0.1.0, not on a detached HEAD',
                 assert_raises(Release::Error) { release(detached).prepare }.message
    assert_equal "git status failed; #{RESUME}",
                 assert_raises(Release::Error) { release(FakeRunner.new(failing: %w[git status])).prepare }.message

    File.write(tmp('lib/keryx/version.rb'), "module Keryx\nend\n")

    error = assert_raises(Release::Error) { Release.new(root: tmp, runner: nil).version }

    assert_equal 'lib/keryx/version.rb sets no VERSION', error.message
  end

  def test_prepare_on_a_finished_release_branch_writes_nothing
    runner = FakeRunner.new(PUSHED.merge(OPEN_PULL => ["#{REPOSITORY}/pull/1", true]))
    release(runner, changelog: RELEASED).prepare

    assert_empty writes(runner)
    assert_equal "#{REPOSITORY}/pull/1 is open already.\nWhen the pull request merges, run bin/release tag on main.\n",
                 @out.string
  end

  def test_prepare_refuses_a_release_branch_that_holds_more_than_the_release
    [
      ON_BRANCH.merge(%w[git rev-list --count HEAD..origin/main] => ['1', true]),
      ON_BRANCH.merge(%w[git rev-list --count origin/main..HEAD] => ['2', true]),
      ON_BRANCH.merge(%w[git status --porcelain] => [" M CHANGELOG.md\n?? notes.md", true]),
      COMMITTED.merge(%w[git diff --name-only origin/main HEAD] => ["CHANGELOG.md\nREADME.md", true]),
      COMMITTED.merge(BRANCH_ON_ORIGIN => ["def\trefs/heads/release/v0.1.0", true])
    ].each do |answers|
      runner = FakeRunner.new(answers)

      assert_raises(Release::Error) { release(runner, changelog: RELEASED).prepare }
      assert_empty writes(runner)
    end
  end

  def test_prepare_never_releases_a_version_twice
    assert_raises(Release::Error) { release(FakeRunner.new(main: RELEASED), changelog: RELEASED).prepare }

    tagged = FakeRunner.new({ %w[git ls-remote origin refs/tags/v0.1.0] => ["abc\trefs/tags/v0.1.0", true] })
    error = assert_raises(Release::Error) { release(tagged).prepare }

    assert_equal 'keryx 0.1.0 is already released', error.message
    refute_includes tagged.commands, %w[git switch --create release/v0.1.0]
  end

  def test_prepare_starts_only_from_a_clean_main_that_matches_origin
    {
      %w[git branch --show-current] => ['topic', true],
      %w[git status --porcelain] => [' M README.md', true],
      %w[git rev-parse origin/main] => ['def', true]
    }.each do |command, answer|
      runner = FakeRunner.new({ command => answer })

      assert_raises(Release::Error) { release(runner).prepare }
      refute(runner.commands.any? { it.first(2) == %w[git switch] })
    end
  end

  def test_tag_signs_and_pushes_the_tag_of_the_released_version
    runner = FakeRunner.new
    release(runner, changelog: RELEASED).tag

    assert_equal [['git', 'tag', '--sign', '--message', 'keryx 0.1.0', 'v0.1.0'],
                  %w[git push origin refs/tags/v0.1.0]], runner.commands.last(2)
    assert_match(/\APushed v0\.1\.0\. The release workflow publishes it/, @out.string)
  end

  def test_tag_explains_how_to_resume_after_its_push_failed
    runner = FakeRunner.new({ %w[git rev-parse --quiet --verify refs/tags/v0.1.0] => ['abc', true] })
    error = assert_raises(Release::Error) { release(runner, changelog: RELEASED).tag }

    assert_equal 'v0.1.0 is in this clone but not on origin, as when pushing it failed; delete it with ' \
                 'git tag -d v0.1.0 and run bin/release tag again', error.message
    refute(runner.commands.any? { it.first(2) == %w[git push] })
  end

  def test_tag_never_moves_a_tag_origin_has
    runner = FakeRunner.new({ %w[git ls-remote origin refs/tags/v0.1.0] => ["abc\trefs/tags/v0.1.0", true] })
    error = assert_raises(Release::Error) { release(runner, changelog: RELEASED).tag }

    assert_equal 'v0.1.0 already exists', error.message
    refute(runner.commands.any? { it.first(2) == %w[git tag] })
  end

  def test_tag_waits_for_the_release_pull_request
    runner = FakeRunner.new
    error = assert_raises(Release::Error) { release(runner).tag }

    assert_match(/has no section for 0\.1\.0/, error.message)
    refute(runner.commands.any? { it.first(2) == %w[git tag] })
  end

  def test_the_script_reports_usage_and_errors_through_its_exit_status
    _, usage, status = Open3.capture3(RbConfig.ruby, BIN)

    assert_equal 2, status.exitstatus
    assert_match(%r{\Ausage: bin/release prepare}, usage)

    _, error, status = Open3.capture3(RbConfig.ruby, BIN, 'notes', '0.0.0')

    assert_equal 1, status.exitstatus
    assert_equal "bin/release: CHANGELOG.md has no section for 0.0.0\n", error
  end
end
