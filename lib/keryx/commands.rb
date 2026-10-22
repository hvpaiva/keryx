# frozen_string_literal: true

require_relative 'commands/join'
require_relative 'commands/leave'
require_relative 'commands/whoami'
require_relative 'commands/who'
require_relative 'commands/send'
require_relative 'commands/ask'
require_relative 'commands/inbox'
require_relative 'commands/read'
require_relative 'commands/reply'
require_relative 'commands/wait'
require_relative 'commands/status'
require_relative 'commands/ring'
require_relative 'commands/hook'
require_relative 'commands/skill'
require_relative 'commands/completion'
require_relative 'commands/version'
require_relative 'commands/help'
require_relative 'commands/complete'

module Keryx
  module Commands
    # Help lists them in this order within each section.
    ALL = [Join, Leave, Whoami, Who, Send, Ask, Inbox, Read, Reply, Wait, Status, Ring, Hook, Skill, Completion,
           Version, Help, Complete].freeze
  end
end
