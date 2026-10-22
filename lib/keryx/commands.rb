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
require_relative 'commands/version'
require_relative 'commands/help'

module Keryx
  module Commands
    # Help lists them in this order within each section.
    ALL = [Join, Leave, Whoami, Who, Send, Ask, Inbox, Read, Reply, Wait, Version, Help].freeze
  end
end
