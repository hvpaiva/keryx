# frozen_string_literal: true

module Keryx
  # Every failure reported to the user. The CLI prints the message after "error:" and exits with
  # exit_status, so no backtrace reaches the terminal.
  class Error < StandardError
    def exit_status = 1
  end

  # A command line keryx cannot run: an unknown command or flag, a missing or extra argument.
  class UsageError < Error
    def exit_status = 2
  end

  # keryx wait gave up before the reply arrived.
  class WaitTimeout < Error
    def exit_status = 3
  end
end
