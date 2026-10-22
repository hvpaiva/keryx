# frozen_string_literal: true

require 'test_helper'

class VersionTest < Minitest::Test
  def test_the_version_is_semantic
    assert_match(/\A\d+\.\d+\.\d+\z/, Keryx::VERSION)
  end

  def test_the_gem_has_no_runtime_dependencies
    spec = Gem::Specification.load(File.expand_path('../../keryx.gemspec', __dir__))

    assert_empty spec.runtime_dependencies
  end
end
