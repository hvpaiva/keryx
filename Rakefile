# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'bundler/audit/task'
require 'minitest/test_task'
require 'open3'
require 'rbconfig'
require 'rubocop/rake_task'
require 'tempfile'

# The gates sit a little under what test:cov measures and rise with it.
MINIMUM_LINE_COVERAGE = 97
MINIMUM_BRANCH_COVERAGE = 87

# Minitest puts the prelude in a single-quoted shell string, so it is one line without quotes of its own.
COVERAGE_PRELUDE = [
  'require "simplecov"',
  'SimpleCov.start do',
  'merging false',
  'enable_coverage :branch',
  'cover "lib/**/*.rb"',
  'skip "lib/keryx/version.rb"',
  "minimum_coverage line: #{MINIMUM_LINE_COVERAGE}, branch: #{MINIMUM_BRANCH_COVERAGE}",
  'end'
].join('; ')

Minitest::TestTask.create(:test) do |t|
  t.warning = true
  t.test_globs = ['test/**/*_test.rb']
end

Minitest::TestTask.create('test:cov') do |t|
  t.warning = true
  t.test_globs = ['test/**/*_test.rb']
  t.test_prelude = COVERAGE_PRELUDE
end

RuboCop::RakeTask.new

Bundler::Audit::Task.new

desc 'Update the advisory database, then check Gemfile.lock'
task audit: %w[bundle:audit:update bundle:audit:check]

namespace :lint do
  desc 'Run shellcheck on bin/setup and on the bash completion script keryx prints'
  task :shell do
    abort 'shellcheck is not installed; install it with: mise install shellcheck' unless
      system('shellcheck', '--version', out: File::NULL, err: File::NULL)

    sh 'shellcheck', '-s', 'bash', 'bin/setup'
    script, status = Open3.capture2(RbConfig.ruby, '-Ilib', 'exe/keryx', 'completion', 'bash')
    abort 'keryx completion bash failed' unless status.success?

    Tempfile.create(['keryx-completion-', '.bash']) do |file|
      file.write(script)
      file.flush
      sh 'shellcheck', '-s', 'bash', file.path
    end
  end
end

Rake::Task['release'].clear
desc 'Refuse: releases go through bin/release (docs/maintenance.md)'
task :release do
  abort 'keryx releases through bin/release; see docs/maintenance.md'
end

desc 'Run what CI runs: RuboCop, shellcheck, the tests with coverage and the advisory audit'
task check: %w[rubocop lint:shell test:cov audit]

task default: %i[test rubocop]
