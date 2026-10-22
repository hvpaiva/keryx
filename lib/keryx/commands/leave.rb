# frozen_string_literal: true

require_relative '../cli/command'

module Keryx
  module Commands
    class Leave < CLI::Command
      define 'leave', section: 'Session Commands',
                      summary: 'Release the address this session holds',
                      description: "Release the address this session holds.\n\n" \
                                   'The address and its mailbox stay: messages keep arriving, and the next ' \
                                   'session to join the name finds them.',
                      examples: [['Release the address before handing the pane to another task', 'leave']]

      def call(_arguments)
        name = app.identity.held or raise Error, 'this session holds no address'
        app.store.unbind(name)
        terminal.puts("Left #{terminal.paint(:address, app.full(name))}. Its mailbox keeps receiving.")
        nil
      end
    end
  end
end
