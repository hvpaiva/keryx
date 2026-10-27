# frozen_string_literal: true

require 'date'
require 'open3'

class Release
  REPOSITORY = 'https://github.com/hvpaiva/keryx'
  VERSION_FILE = 'lib/keryx/version.rb'
  CHANGELOG = 'CHANGELOG.md'
  START_OVER = 'start over as docs/maintenance.md says under Recover'
  # What git status --porcelain prints when the changelog alone changed, staged or not.
  DATED = /\A[ M]{2} #{Regexp.escape(CHANGELOG)}\z/

  class Error < StandardError; end

  # A command that ran and failed, as against a refusal before anything ran.
  class Failed < Error; end

  module Changelog
    SECTION_END = /(?=^## \[|^\[Unreleased\]: |\z)/
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

  # The tag, the GitHub release and RubyGems date a release in UTC, so the changelog does too.
  def initialize(root:, runner:, out: $stdout, today: Time.now.getutc.to_date)
    @root = root
    @runner = runner
    @out = out
    @today = today
  end

  def version
    read(VERSION_FILE)[/VERSION = '([^']+)'/, 1] or raise Error, "#{VERSION_FILE} sets no VERSION"
  end

  # Each step is skipped when an earlier run already took it, so after a failed command a second run goes on from
  # there, on the release branch or back on main.
  def prepare
    branch = "release/v#{version}"
    on_branch('main', branch) == 'main' ? start(branch) : fetch_unreleased
    commit_release(branch)
    push(branch)
    open_pull_request(branch)
    @out.puts 'When the pull request merges, run bin/release tag on main.'
  rescue Failed, Errno::ENOENT => e
    raise Failed, "#{e.message}; once its cause is fixed, run bin/release prepare again and it goes on from there"
  end

  def tag
    on_branch('main')
    in_sync_with_origin
    unless Changelog.released?(read(CHANGELOG), version)
      raise Error, "#{CHANGELOG} on main has no section for #{version}; merge the pull request of bin/release prepare"
    end
    raise Error, "v#{version} already exists" if remote_tag?
    if local_tag?
      raise Error, "v#{version} is in this clone but not on origin, as when pushing it failed; delete it with " \
                   "git tag -d v#{version} and run bin/release tag again"
    end

    run('git', 'tag', '--sign', '--message', "keryx #{version}", "v#{version}")
    run('git', 'push', 'origin', "refs/tags/v#{version}")
    @out.puts "Pushed v#{version}. The release workflow publishes it, see #{REPOSITORY}/actions/workflows/release.yml"
  end

  def notes(version) = Changelog.notes(read(CHANGELOG), version)

  private

  def title = "chore: release #{version}"

  def start(branch)
    in_sync_with_origin
    refuse_released
    return run('git', 'switch', branch) if local_branch?(branch)

    changelog = Changelog.cut(read(CHANGELOG), version, @today.iso8601)
    run('git', 'switch', '--create', branch)
    File.write(path(CHANGELOG), changelog)
  end

  # The release branch holds origin/main and at most the release commit, or the dated changelog it commits.
  def commit_release(branch)
    unless capture('git', 'rev-list', '--count', 'HEAD..origin/main') == '0'
      raise Error, "origin/main moved on after #{branch} was cut, so its changelog misses changes; #{START_OVER}"
    end

    case [capture('git', 'rev-list', '--count', 'origin/main..HEAD'), capture('git', 'status', '--porcelain')]
    in ['1', ''] if release_commit? then return
    in ['0', ''] then File.write(path(CHANGELOG), Changelog.cut(read(CHANGELOG), version, @today.iso8601))
    in ['0', DATED] if Changelog.released?(read(CHANGELOG), version) then nil
    else raise Error, "#{branch} holds changes besides the release of #{version}; #{START_OVER}"
    end
    run('git', 'commit', '--gpg-sign', '--message', title, '--', CHANGELOG)
  end

  def release_commit?
    capture('git', 'diff', '--name-only', 'origin/main', 'HEAD') == CHANGELOG &&
      Changelog.released?(read(CHANGELOG), version)
  end

  def push(branch)
    pushed = capture('git', 'ls-remote', 'origin', "refs/heads/#{branch}").split("\t").first
    return run('git', 'push', '--set-upstream', 'origin', branch) if pushed.nil?
    return if pushed == capture('git', 'rev-parse', 'HEAD')

    raise Error, "origin has another #{branch}; #{START_OVER}"
  end

  def open_pull_request(branch)
    open = capture('gh', 'pr', 'list', '--head', branch, '--state', 'open', '--json', 'url', '--jq', '.[].url')
    return @out.puts("#{open} is open already.") unless open.empty?

    run('gh', 'pr', 'create', '--base', 'main', '--head', branch, '--title', title, '--body', pull_request_body)
  end

  def pull_request_body
    "Releases keryx #{version}. Once this merges, `bin/release tag` on main signs and pushes " \
      "v#{version}, and the release workflow publishes it.\n\n#{notes(version)}\n"
  end

  def on_branch(*names)
    branch = capture('git', 'branch', '--show-current')
    return branch if names.include?(branch)

    raise Error, "run bin/release on #{names.join(' or ')}, not on #{branch.empty? ? 'a detached HEAD' : branch}"
  end

  def in_sync_with_origin
    raise Error, 'the working tree has uncommitted changes' unless capture('git', 'status', '--porcelain').empty?

    fetch
    return if capture('git', 'rev-parse', 'HEAD') == capture('git', 'rev-parse', 'origin/main')

    raise Error, 'main differs from origin/main; pull or reset it first'
  end

  def fetch = run('git', 'fetch', '--quiet', '--tags', 'origin', 'main')

  def fetch_unreleased
    fetch
    refuse_released
  end

  def refuse_released
    released = Changelog.released?(capture('git', 'show', "origin/main:#{CHANGELOG}"), version)
    raise Error, "keryx #{version} is already released" if released || tagged?
  end

  def tagged? = local_tag? || remote_tag?

  def local_tag? = verified?(tag_ref)

  def local_branch?(branch) = verified?("refs/heads/#{branch}")

  def verified?(ref) = @runner.capture('git', 'rev-parse', '--quiet', '--verify', ref).last

  def remote_tag? = !capture('git', 'ls-remote', 'origin', tag_ref).empty?

  def tag_ref = "refs/tags/v#{version}"

  def capture(*argv)
    out, ok = @runner.capture(*argv)
    raise Failed, "#{command(argv)} failed" unless ok

    out
  end

  def run(*argv)
    @runner.run(*argv) or raise Failed, "#{command(argv)} failed"
  end

  # The program and its subcommand, without the options after them, one of which may be a pull request's whole body.
  def command(argv) = argv.take_while { !it.start_with?('-') }.join(' ')

  def read(file) = File.read(path(file))

  def path(file) = File.join(@root, file)
end
