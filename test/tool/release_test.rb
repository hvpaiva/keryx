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

  class FakeRunner
    attr_reader :commands

    def initialize(answers = {})
      @answers = {
        %w[git branch --show-current] => ['main', true],
        %w[git rev-parse HEAD] => ['abc', true],
        %w[git rev-parse origin/main] => ['abc', true],
        %w[git rev-parse --quiet --verify refs/tags/v0.1.0] => ['', false]
      }.merge(answers)
      @commands = []
    end

    def capture(*argv)
      @commands << argv
      @answers.fetch(argv, ['', true])
    end

    def run(*argv) = @commands << argv
  end

  def release(runner = FakeRunner.new, changelog: UNRELEASED)
    FileUtils.mkdir_p(tmp('lib/keryx'))
    File.write(tmp('lib/keryx/version.rb'), "module Keryx\n  VERSION = '0.1.0'\nend\n")
    File.write(tmp('CHANGELOG.md'), changelog)
    @out = StringIO.new
    Release.new(root: tmp, runner:, out: @out, today: TODAY)
  end

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

  def test_prepare_opens_a_pull_request_that_dates_the_changelog
    runner = FakeRunner.new
    release(runner).prepare
    title = 'chore: release 0.1.0'

    assert_equal RELEASED, File.read(tmp('CHANGELOG.md'))
    assert_equal [%w[git switch --create release/v0.1.0], ['git', 'commit', '--message', title, '--', 'CHANGELOG.md'],
                  %w[git push --set-upstream origin release/v0.1.0]], runner.commands[-4..-2]
    assert_equal ['gh', 'pr', 'create', '--base', 'main', '--head', 'release/v0.1.0', '--title', title],
                 runner.commands.last.first(9)
    assert_includes runner.commands.last.last, "### Added\n\n- Mailboxes."
    assert_equal "When the pull request merges, run bin/release tag on main.\n", @out.string
  end

  def test_prepare_never_releases_a_version_twice
    assert_raises(Release::Error) { release(changelog: RELEASED).prepare }

    tagged = FakeRunner.new(%w[git ls-remote origin refs/tags/v0.1.0] => ["abc\trefs/tags/v0.1.0", true])
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
      runner = FakeRunner.new(command => answer)

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
