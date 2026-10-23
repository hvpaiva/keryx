# frozen_string_literal: true

require 'securerandom'
require 'socket'
require_relative 'error'

module Keryx
  # MEMBER.TEAM@HOST, with /SESSION for one incarnation. An address from before team names has no team.
  Address = Data.define(:member, :team, :host, :session) do
    def initialize(member:, host:, team: nil, session: nil) = super
  end

  class Address
    SEGMENT = '[a-z][a-z0-9-]{0,31}'
    NAME = /\A#{SEGMENT}\z/
    HOST = /\A[a-z0-9][a-z0-9-]{0,62}\z/
    # Crockford's base32 in lowercase, without i, l, o and u.
    SESSION_ALPHABET = '0123456789abcdefghjkmnpqrstvwxyz'
    SESSION_SIZE = 6
    SESSION = /\A[#{SESSION_ALPHABET}]{#{SESSION_SIZE}}\z/
    KEY = /\A(?<member>#{SEGMENT})(?:\.(?<team>#{SEGMENT}))?\z/
    FULL = %r{\A(?<key>[^@/]*)@(?<host>[^@/]*)(?:/(?<session>[^@/]*))?\z}
    NAME_RULE = 'a lowercase letter, then up to 31 lowercase letters, digits or hyphens'
    SPELLING = 'MEMBER.TEAM@HOST'
    LOCAL = 'local'
    SYSTEM = 'system'
    RESERVED = [LOCAL, SYSTEM].freeze

    # The full spelling, as messages and records carry it.
    def self.parse(text)
      parts = FULL.match(text.to_s) or raise Error, "invalid address #{text.to_s.inspect}: expected #{SPELLING}"
      raise Error, "invalid host #{parts[:host].inspect} in #{text.to_s.inspect}" unless HOST.match?(parts[:host])

      address = from_key(parts[:key], host: parts[:host])
      session = parts[:session]
      return address unless session

      check_session(address, session, text)
      address.with(session:)
    end

    def self.from_key(key, host:)
      parts = KEY.match(key.to_s) or raise Error, "invalid name #{key.to_s.inspect}: #{NAME_RULE}, with .TEAM " \
                                                  'spelled the same'
      new(member: parts[:member], team: parts[:team], host:)
    end

    # KEY, or KEY/SESSION for one incarnation of the address: how a command names the session it acts as.
    def self.from_name(name, host:)
      key, session = name.to_s.split('/', 2)
      address = from_key(key, host:)
      session.nil? ? address : parse("#{address}/#{session}")
    end

    # A session id that none of TAKEN, the sessions bound to the address, already has.
    def self.draw_session(taken = [], random: SecureRandom)
      loop do
        session = Array.new(SESSION_SIZE) { SESSION_ALPHABET[random.random_number(SESSION_ALPHABET.size)] }.join
        return session unless taken.include?(session)
      end
    end

    def self.key?(text) = KEY.match?(text.to_s)

    def self.valid?(text)
      parse(text)
      true
    rescue Error
      false
    end

    def self.check_session(address, session, text)
      raise Error, "#{address} has no team, so it has no session addresses" if address.flat?
      return if SESSION.match?(session)

      raise Error, "invalid session #{session.inspect} in #{text.to_s.inspect}: #{SESSION_SIZE} characters of " \
                   "#{SESSION_ALPHABET}"
    end
    private_class_method :check_session

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

    def key = team ? "#{member}.#{team}" : member

    def name = session ? "#{key}/#{session}" : key

    def stable = with(session: nil)

    def flat? = team.nil?

    def reserved? = RESERVED.include?(team)

    def to_s = "#{key}@#{host}#{"/#{session}" if session}"

    def local?(local_host) = host == local_host
  end
end
