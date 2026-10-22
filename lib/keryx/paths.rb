# frozen_string_literal: true

module Keryx
  class Paths
    APP = 'keryx'
    STATE_DEFAULT = File.join('.local', 'state').freeze
    CONFIG_DEFAULT = '.config'
    CONFIG_FILE = 'config'

    def initialize(env)
      @env = env
    end

    def root
      absolute(@env['KERYX_HOME']) || File.join(absolute(@env['XDG_STATE_HOME']) || default_state, APP)
    end

    def config_home = absolute(@env['XDG_CONFIG_HOME']) || File.join(home, CONFIG_DEFAULT)

    def config = File.join(config_home, APP, CONFIG_FILE)

    private

    def default_state = File.join(home, STATE_DEFAULT)

    def home
      value = @env['HOME'].to_s
      value.empty? ? Dir.home : value
    end

    def absolute(value)
      value = value.to_s
      value if !value.empty? && File.absolute_path?(value)
    end
  end
end
