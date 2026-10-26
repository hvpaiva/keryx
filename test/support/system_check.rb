# frozen_string_literal: true

require 'keryx'

# Every test sees a check file that never exists unless it names its own, so none reads the machine's
# /etc/keryx/check. test_helper requires this first, and the tests that run exe/keryx preload it with -r.
module SystemCheck
  ABSENT = '/nonexistent/keryx/check'
  PRELOAD = __FILE__

  def initialize(path: ABSENT, trusted: Keryx::CheckConfig::ROOT) = super
end

Keryx::CheckConfig.prepend(SystemCheck)
