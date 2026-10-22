# frozen_string_literal: true

require 'json'
require_relative 'address'
require_relative 'error'
require_relative 'identity'
require_relative 'message'
require_relative 'ulid'

module Keryx
  class Receiver
    def initialize(store:, bell:, host:, person:)
      @store = store
      @bell = bell
      @host = host
      @person = person
    end

    def receive(line)
      message = Message.from_json(line)
      to = Address.parse(message.to, local_host: @host)
      refusal = refusal(message, to)
      return receipt(message.id, 'refused', detail: refusal) if refusal

      @store.create_address(to.name, role: Identity::HUMAN_ROLE) unless @store.address?(to.name)
      status = @store.deliver(to.name, message)
      bell = @bell.ring(to.name, [message]).record if status == :delivered
      receipt(message.id, status.to_s, bell:)
    rescue Error, SystemCallError => e
      receipt(claimed_id(line), 'refused', detail: e.message)
    end

    private

    def refusal(message, to)
      return "#{message.to} is not on #{@host}" unless to.local?(@host)
      if Address.parse(message.from, local_host: @host).local?(@host)
        return "#{message.from} is on #{@host} and cannot arrive from another machine"
      end

      "no address #{message.to}" unless @store.address?(to.name) || to.name == @person
    end

    def receipt(id, status, detail: nil, bell: nil)
      { 'id' => id, 'status' => status, 'detail' => detail, 'bell' => bell }.compact
    end

    def claimed_id(line)
      data = JSON.parse(line)
      data['id'] if data.is_a?(Hash) && Ulid.valid?(data['id'])
    rescue JSON::ParserError
      nil
    end
  end
end
