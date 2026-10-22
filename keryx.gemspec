# frozen_string_literal: true

require_relative 'lib/keryx/version'

Gem::Specification.new do |spec|
  spec.name = 'keryx'
  spec.version = Keryx::VERSION
  spec.authors = ['Highlander Paiva']
  spec.email = ['contact@hvpaiva.dev']

  spec.summary = 'Reliable messaging between AI coding agent sessions'
  spec.description = 'keryx gives independent coding agent sessions, such as Claude Code, Codex and Cursor ' \
                     'running side by side in terminal panes, mailboxes whose addresses outlive any session. ' \
                     'Every message is written to the mailbox before anything else happens, then announced to ' \
                     "the recipient through its harness's own channel, so nothing depends on an agent " \
                     'remembering to check.'
  spec.homepage = 'https://github.com/hvpaiva/keryx'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.4'

  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'bug_tracker_uri' => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }

  # Only tracked files ship, so the gem has to be built from a git checkout.
  shipped = %w[lib/ exe/ README.md CHANGELOG.md LICENSE.txt]
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).select { |file| file.start_with?(*shipped) }
  end
  spec.bindir = 'exe'
  spec.executables = ['keryx']
  spec.require_paths = ['lib']
end
