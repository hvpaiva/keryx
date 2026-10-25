# frozen_string_literal: true

require_relative 'address'
require_relative 'error'

module Keryx
  # Turns the name a user typed into a full address before anything is stored. Resolving grants nothing.
  class Resolver
    def initialize(store:, host:)
      @store = store
      @host = host
    end

    # SENDER is the store name the command acts as, or nil, or a block that gives it, asked only for a bare member.
    def resolve(text, sender:)
      text = text.to_s
      return Address.parse(text) if text.include?('@')

      base, session = text.split('/', 2)
      address = base.include?('.') ? Address.from_key(base, host: @host) : member(base, sender)
      session ? Address.parse("#{address}/#{session}") : address
    end

    private

    def member(name, sender)
      Address.validate_name(name)
      sender = sender.call if sender.respond_to?(:call)
      team = sender && Address.from_name(sender, host: @host).team
      return Address.new(member: name, team:, host: @host) if team && !Address::RESERVED.include?(team)

      only(name)
    end

    # A sender with no team of its own names a member that only one team on this host has.
    def only(name)
      matches = @store.current_names.map { Address.from_key(it, host: @host) }.select { it.team && it.member == name }
      return matches.first if matches.one?

      raise Error, "no address #{name}.TEAM on #{@host}; name the team, as #{name}.TEAM" if matches.empty?

      listed = "#{matches[0...-1].join(', ')} and #{matches.last}"
      raise Error, "#{name} matches #{listed}; name the team, as #{matches.first.key}"
    end
  end
end
