# frozen_string_literal: true

require_relative 'address'
require_relative 'error'
require_relative 'resolver'

module Keryx
  class Identity
    HUMAN_ROLE = 'human'
    NOT_JOINED = "this %s session holds no address; run 'keryx join MEMBER.TEAM' in it first"
    # The sender of what keryx itself posts: the courier's notices and spawn's quotes of a dialog.
    SYSTEM = "keryx.#{Address::SYSTEM}".freeze

    def initialize(store:, caller:, env:, host: nil)
      @store = store
      @caller = caller
      @env = env
      @host = host
    end

    def current(as: nil)
      return existing(as) if as

      name = held
      return name if name
      raise Error, format(NOT_JOINED, @caller.harness) if @caller.agent?

      @store.create_address(human_name, role: HUMAN_ROLE).name
    end

    # The key of the address this session holds, or KEY/SESSION when join --force took the address from it while it
    # ran. The holder is matched first, so a session that took over in the pane of the one it displaced is the holder.
    # An agent holds no address in a reserved scope, even one an older keryx let it join.
    def held
      @store.address_names.each do |name|
        next if @caller.agent? && reserved?(name)

        found = @store.incarnations(name).find do |incarnation|
          occupant = @store.reporting { @store.occupant(incarnation) }
          occupant && @caller.holds?(occupant)
        end
        return found if found
      end
      nil
    end

    # A person at a terminal is a member of the local scope, named after USER.
    def human_name
      name = @env['USER'].to_s.downcase.gsub(/[^a-z0-9-]/, '-').sub(/\A[^a-z]+/, '')[0, 32]
      "#{Address::NAME.match?(name) ? name : 'human'}.#{Address::LOCAL}"
    end

    private

    def reserved?(name) = Address.from_key(name, host: @host).reserved?

    def existing(text)
      address = Resolver.new(store: @store, host: @host).resolve(text, sender: held)
      raise Error, "#{address} is on another machine; --as names an address on #{@host}" unless address.local?(@host)

      name = address.key
      raise Error, "no address #{address}; addresses are created by 'keryx join'" unless @store.address?(name)
      raise Error, "#{address} is retired; 'keryx join #{name} --revive' brings it back" if @store.retired?(name)

      address.session ? incarnation(address) : name
    end

    # The holder's session acts as the address; a displaced one acts as its session address.
    def incarnation(address)
      occupant = @store.occupant(address.name) or
        raise Error, "the session of #{address} left; the address is #{address.stable}"
      @store.occupant(address.key)&.session == occupant.session ? address.key : address.name
    end
  end
end
