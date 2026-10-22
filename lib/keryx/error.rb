# frozen_string_literal: true

module Keryx
  class Error < StandardError
    def exit_status = 1
  end

  class UsageError < Error
    def exit_status = 2
  end

  class WaitTimeout < Error
    def exit_status = 3
  end
end
