# frozen_string_literal: true

require 'test_helper'

class ConventionsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # A non-ASCII byte can hide a bidirectional control that makes code read differently than it runs.
  ASCII_TREES = %w[lib exe bin test].freeze

  def test_code_scripts_and_tests_are_ascii
    files = ASCII_TREES.flat_map { Dir.glob("#{it}/**/*", base: ROOT) }.select { File.file?(File.join(ROOT, it)) }

    assert_empty(files.reject { File.binread(File.join(ROOT, it)).ascii_only? })
    refute_empty files
  end
end
