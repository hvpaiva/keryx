# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'bundler/audit/task'
require 'minitest/test_task'
require 'rubocop/rake_task'

# The gates sit a little under what test:cov measures and rise with it.
MINIMUM_LINE_COVERAGE = 95
MINIMUM_BRANCH_COVERAGE = 85

# Minitest joins the prelude into one shell string, so it stays on one line without quotes of its
# own. Bundler loads version.rb through the gemspec before SimpleCov starts, so that file is left
# out instead of counting as never run.
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

task default: %i[test rubocop]
