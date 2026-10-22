# frozen_string_literal: true

module Keryx
  # Where keryx keeps its mailboxes, following the XDG Base Directory Specification. Reads only
  # the environment it is given, so tests never touch ENV.
  class Paths
    APP = 'keryx'
    STATE_DEFAULT = File.join('.local', 'state').freeze

    def initialize(env)
      @env = env
    end

    # KERYX_HOME, then $XDG_STATE_HOME/keryx, then ~/.local/state/keryx. The specification says
    # a relative XDG path is invalid and ignored; the same holds for KERYX_HOME.
    def root
      absolute(@env['KERYX_HOME']) || File.join(absolute(@env['XDG_STATE_HOME']) || default_state, APP)
    end

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
