# frozen_string_literal: true

require_relative 'address'
require_relative 'error'

module Keryx
  class Identity
    HUMAN_ROLE = 'human'
    NOT_JOINED = "this %s session holds no address; run 'keryx join NAME' in it first"

    def initialize(store:, caller:, env:)
      @store = store
      @caller = caller
      @env = env
    end

    def current(as: nil)
      return existing(as) if as

      name = held
      return name if name
      raise Error, format(NOT_JOINED, @caller.harness) if @caller.agent?

      @store.create_address(human_name, role: HUMAN_ROLE).name
    end

    def held
      @store.address_names.find do |name|
        occupant = @store.occupant(name)
        occupant && @caller.holds?(occupant)
      end
    end

    def human_name
      name = @env['USER'].to_s.downcase.gsub(/[^a-z0-9-]/, '-').sub(/\A[^a-z]+/, '')[0, 32]
      Address::NAME.match?(name) ? name : 'human'
    end

    private

    def existing(name)
      Address.validate_name(name)
      raise Error, "no address #{name}; addresses are created by 'keryx join'" unless @store.address?(name)

      name
    end
  end
end
