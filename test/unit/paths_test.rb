# frozen_string_literal: true

require 'test_helper'

class PathsTest < Minitest::Test
  def root(env) = Keryx::Paths.new(env).root

  def config(env) = Keryx::Paths.new(env).config

  def test_keryx_home_wins
    assert_equal '/srv/keryx', root('KERYX_HOME' => '/srv/keryx', 'XDG_STATE_HOME' => '/x', 'HOME' => '/home/u')
  end

  def test_xdg_state_home_comes_next
    assert_equal '/x/keryx', root('XDG_STATE_HOME' => '/x', 'HOME' => '/home/u')
  end

  def test_the_default_is_under_home
    assert_equal '/home/u/.local/state/keryx', root('HOME' => '/home/u')
  end

  def test_relative_and_empty_values_are_ignored
    assert_equal '/home/u/.local/state/keryx', root('KERYX_HOME' => 'rel', 'XDG_STATE_HOME' => '', 'HOME' => '/home/u')
  end

  def test_the_config_file_is_under_xdg_config_home
    assert_equal '/c/keryx/config', config('XDG_CONFIG_HOME' => '/c', 'HOME' => '/home/u')
  end

  def test_the_config_file_defaults_to_dot_config_under_home
    ['rel', '', nil].each do |xdg|
      assert_equal '/home/u/.config/keryx/config', config('XDG_CONFIG_HOME' => xdg, 'HOME' => '/home/u')
    end
  end

  def test_keryx_home_does_not_move_the_config_file
    assert_equal '/c/keryx/config', config('KERYX_HOME' => '/srv/keryx', 'XDG_CONFIG_HOME' => '/c')
  end
end
