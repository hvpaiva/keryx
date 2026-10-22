# frozen_string_literal: true

require 'json'
require_relative '../cli/command'

module Keryx
  module Commands
    class Receive < CLI::Command
      define '__receive', section: 'Other Commands', hidden: true,
                          summary: 'Store messages another machine forwards over SSH'

      def self.raw? = true

      def call(_arguments)
        app.receiver.receive_all(terminal.input) { terminal.puts(JSON.generate(it)) }
        nil
      end
    end
  end
end
