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
        receiver = app.receiver
        terminal.input.each_line do |line|
          terminal.puts(JSON.generate(receiver.receive(line))) unless line.strip.empty?
        end
        nil
      end
    end
  end
end
