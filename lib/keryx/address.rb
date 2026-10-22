# frozen_string_literal: true

require 'socket'
require_relative 'error'

module Keryx
  Address = Data.define(:name, :host)

  # A mailbox address, NAME@HOST. A bare NAME means the local host.
  class Address
    NAME = /\A[a-z][a-z0-9-]{0,31}\z/
    HOST = /\A[a-z0-9][a-z0-9-]{0,62}\z/
    NAME_RULE = 'a lowercase letter, then up to 31 lowercase letters, digits or hyphens'

    def self.parse(text, local_host:)
      name, host, *rest = text.to_s.split('@', -1)
      host ||= local_host
      raise Error, "invalid address #{text.to_s.inspect}: expected NAME or NAME@HOST" unless rest.empty?

      validate_name(name)
      raise Error, "invalid host #{host.inspect} in #{text.to_s.inspect}" unless HOST.match?(host)

      new(name:, host:)
    end

    def self.validate_name(name)
      return name if NAME.match?(name.to_s)

      raise Error, "invalid name #{name.to_s.inspect}: #{NAME_RULE}"
    end

    # The local host name: KERYX_HOST when set, otherwise the first label of the machine's host
    # name, lowercased, with anything outside [a-z0-9-] turned into a hyphen.
    def self.local_host(env, hostname: Socket.gethostname)
      configured = env['KERYX_HOST'].to_s
      unless configured.empty?
        raise Error, "KERYX_HOST #{configured.inspect} is not a valid host name" unless HOST.match?(configured)

        return configured
      end

      derived = hostname.to_s.split('.').first.to_s.downcase.gsub(/[^a-z0-9-]/, '-').sub(/\A-+/, '')
      derived.empty? ? 'localhost' : derived[0, 63]
    end

    def to_s = "#{name}@#{host}"

    def local?(local_host) = host == local_host
  end
end
