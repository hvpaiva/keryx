# frozen_string_literal: true

require_relative 'commands/join'
require_relative 'commands/spawn'
require_relative 'commands/expect'
require_relative 'commands/leave'
require_relative 'commands/retire'
require_relative 'commands/whoami'
require_relative 'commands/who'
require_relative 'commands/send'
require_relative 'commands/ask'
require_relative 'commands/inbox'
require_relative 'commands/sent'
require_relative 'commands/history'
require_relative 'commands/read'
require_relative 'commands/reply'
require_relative 'commands/wait'
require_relative 'commands/withdraw'
require_relative 'commands/status'
require_relative 'commands/ring'
require_relative 'commands/courier'
require_relative 'commands/hook'
require_relative 'commands/wiring'
require_relative 'commands/skill'
require_relative 'commands/completion'
require_relative 'commands/version'
require_relative 'commands/help'
require_relative 'commands/complete'
require_relative 'commands/receive'

module Keryx
  module Commands
    ALL = [Join, Spawn, Expect, Leave, Retire, Whoami, Who, Send, Ask, Inbox, Sent, History, Read, Reply, Wait,
           Withdraw, Status, Ring, Courier, Hook, Wiring, Skill, Completion, Version, Help, Complete, Receive].freeze
  end
end
