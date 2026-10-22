# frozen_string_literal: true

require 'socket'
require_relative 'error'

module Keryx
  Address = Data.define(:name, :host)

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

    def self.local_host(env, config: nil, hostname: Socket.gethostname)
      configured = env['KERYX_HOST'].to_s
      return valid_host(configured, 'KERYX_HOST') unless configured.empty?

      setting = config&.host
      return valid_host(setting.value, "#{config.path}:#{setting.line}: host") if setting

      derived = hostname.to_s.split('.').first.to_s.downcase.gsub(/[^a-z0-9-]/, '-').sub(/\A-+/, '')
      derived.empty? ? 'localhost' : derived[0, 63]
    end

    def self.valid_host(host, source)
      return host if HOST.match?(host)

      raise Error, "#{source} #{host.inspect} is not a valid host name"
    end
    private_class_method :valid_host

    def to_s = "#{name}@#{host}"

    def local?(local_host) = host == local_host
  end
end
