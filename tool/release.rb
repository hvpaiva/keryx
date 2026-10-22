# frozen_string_literal: true

require 'date'
require 'open3'

class Release
  REPOSITORY = 'https://github.com/hvpaiva/keryx'
  VERSION_FILE = 'lib/keryx/version.rb'
  CHANGELOG = 'CHANGELOG.md'

  class Error < StandardError; end

  module Changelog
    SECTION_END = /(?=^## \[|^\[[^\]\n]+\]: |\z)/
    UNRELEASED = /^## \[Unreleased\]\n(?<body>.*?)#{SECTION_END}/m
    UNRELEASED_LINK = /^\[Unreleased\]: .*$/

    module_function

    def cut(text, version, date)
      body = UNRELEASED.match(text)&.[](:body)&.strip
      raise Error, "#{CHANGELOG} has no ## [Unreleased] section" if body.nil?
      raise Error, "#{CHANGELOG} has nothing under ## [Unreleased] to release" if body.empty?
      raise Error, "#{CHANGELOG} has no [Unreleased] link" unless text.match?(UNRELEASED_LINK)

      text.sub(UNRELEASED) { "## [Unreleased]\n\n## [#{version}] - #{date}\n\n#{body}\n\n" }
          .sub(UNRELEASED_LINK) do
            "[Unreleased]: #{REPOSITORY}/compare/v#{version}...HEAD\n" \
              "[#{version}]: #{REPOSITORY}/releases/tag/v#{version}"
          end
    end

    def notes(text, version)
      section = /^## \[#{Regexp.escape(version)}\] - [^\n]*\n(?<body>.*?)#{SECTION_END}/m.match(text)
      raise Error, "#{CHANGELOG} has no section for #{version}" unless section

      section[:body].strip
    end

    def released?(text, version) = text.match?(/^## \[#{Regexp.escape(version)}\] - /)
  end

  class Runner
    def initialize(chdir:)
      @chdir = chdir
    end

    def capture(*argv)
      out, status = Open3.capture2(*argv, chdir: @chdir)
      [out.chomp, status.success?]
    end

    def run(*argv) = system(*argv, chdir: @chdir)
  end

  def initialize(root:, runner:, out: $stdout, today: Date.today)
    @root = root
    @runner = runner
    @out = out
    @today = today
  end

  def version
    read(VERSION_FILE)[/VERSION = '([^']+)'/, 1] or raise Error, "#{VERSION_FILE} sets no VERSION"
  end

  def prepare
    on_main_in_sync
    changelog = read(CHANGELOG)
    raise Error, "keryx #{version} is already released" if Changelog.released?(changelog, version) || tagged?

    cut = Changelog.cut(changelog, version, @today.iso8601)
    branch = "release/v#{version}"
    run('git', 'switch', '--create', branch)
    File.write(path(CHANGELOG), cut)
    run('git', 'commit', '--message', title, '--', CHANGELOG)
    run('git', 'push', '--set-upstream', 'origin', branch)
    run('gh', 'pr', 'create', '--base', 'main', '--head', branch, '--title', title, '--body', pull_request_body(cut))
    @out.puts 'When the pull request merges, run bin/release tag on main.'
  end

  def tag
    on_main_in_sync
    unless Changelog.released?(read(CHANGELOG), version)
      raise Error, "#{CHANGELOG} on main has no section for #{version}; merge the pull request of bin/release prepare"
    end
    raise Error, "v#{version} already exists" if tagged?

    run('git', 'tag', '--sign', '--message', "keryx #{version}", "v#{version}")
    run('git', 'push', 'origin', "refs/tags/v#{version}")
    @out.puts "Pushed v#{version}. The release workflow publishes it, see #{REPOSITORY}/actions/workflows/release.yml"
  end

  def notes(version) = Changelog.notes(read(CHANGELOG), version)

  private

  def title = "chore: release #{version}"

  def pull_request_body(changelog)
    "Releases keryx #{version}. Once this merges, `bin/release tag` on main signs and pushes " \
      "v#{version}, and the release workflow publishes it.\n\n#{Changelog.notes(changelog, version)}\n"
  end

  def on_main_in_sync
    branch = capture('git', 'branch', '--show-current')
    raise Error, "run bin/release on main, not on #{branch.empty? ? 'a detached HEAD' : branch}" unless branch == 'main'
    raise Error, 'the working tree has uncommitted changes' unless capture('git', 'status', '--porcelain').empty?

    run('git', 'fetch', '--quiet', '--tags', 'origin', 'main')
    return if capture('git', 'rev-parse', 'HEAD') == capture('git', 'rev-parse', 'origin/main')

    raise Error, 'main differs from origin/main; pull or reset it first'
  end

  def tagged?
    ref = "refs/tags/v#{version}"
    @runner.capture('git', 'rev-parse', '--quiet', '--verify', ref).last ||
      !capture('git', 'ls-remote', 'origin', ref).empty?
  end

  def capture(*argv)
    out, ok = @runner.capture(*argv)
    raise Error, "#{argv.join(' ')} failed" unless ok

    out
  end

  def run(*argv)
    @runner.run(*argv) or raise Error, "#{argv.join(' ')} failed"
  end

  def read(file) = File.read(path(file))

  def path(file) = File.join(@root, file)
end
