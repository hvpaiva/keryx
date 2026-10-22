# frozen_string_literal: true

require_relative 'keryx/version'
require_relative 'keryx/error'
require_relative 'keryx/text'
require_relative 'keryx/ulid'
require_relative 'keryx/duration'
require_relative 'keryx/address'
require_relative 'keryx/message'
require_relative 'keryx/paths'
require_relative 'keryx/occupant'
require_relative 'keryx/store'
require_relative 'keryx/runner'
require_relative 'keryx/herdr'
require_relative 'keryx/caller'
require_relative 'keryx/identity'
require_relative 'keryx/bell'
require_relative 'keryx/postman'
require_relative 'keryx/roster'
require_relative 'keryx/app'
require_relative 'keryx/cli/terminal'
require_relative 'keryx/cli/dispatcher'
require_relative 'keryx/commands'

# Reliable messaging between AI coding agent sessions.
module Keryx
  # Shared by exe/keryx and the tests, so it returns the exit status instead of exiting.
  # `app_factory` is called with the parsed global options the first time a command needs it.
  def self.run(argv, terminal: CLI::Terminal.system,
               app_factory: ->(globals) { App.new(env: terminal.env, as: globals[:as]) })
    CLI::Dispatcher.new(terminal, commands: Commands::ALL, app_factory:).run(argv)
  end
end
