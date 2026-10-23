# frozen_string_literal: true

require 'json'
require_relative 'address'
require_relative 'error'

module Keryx
  # How Store keeps the incarnations of an address, on the paths Store builds. The holder is named by the address's key,
  # or by KEY/SESSION with its own session; a session join --force displaced while it ran is named by KEY/SESSION and
  # stays bound at its session address until it leaves.
  module Incarnations
    OUTGOING = 'outgoing'

    # The sessions displaced from the address that are still bound to it.
    def outgoing(name)
      Dir.children(File.join(box(name), OUTGOING)).filter_map do |file|
        session = file.delete_suffix('.json')
        session if file.end_with?('.json') && Address::SESSION.match?(session)
      end.sort
    rescue Errno::ENOENT
      []
    end

    # The holder of the address by its key, then each displaced session by KEY/SESSION.
    def incarnations(name) = [name, *outgoing(name).map { "#{name}/#{it}" }]

    # The session the holder had keeps the address at its session address while it runs.
    def displace(name, occupant)
      make_dirs(box(name), [OUTGOING])
      write_atomic(outgoing_file(name, occupant.session), JSON.generate(occupant.record))
    end

    # Which messages the incarnation NAME sees. A displaced session lists only the mail to its session address, and
    # opens by id the mail to the address as well, which holds the work it took before it was displaced. The holder,
    # by its key or its session, sees all but the mail to a displaced session, which includes the mail to a session
    # that left. With SIDE :from, the same holds for the mail each incarnation sent.
    def sees(name, by_id: false, side: :to)
      key, session = split(name)
      displaced = outgoing(key)
      session_of = ->(message) { Address.parse(message.public_send(side)).session }
      return ->(message) { !displaced.include?(session_of.call(message)) } unless displaced.include?(session)

      targets = by_id ? [session, nil] : [session]
      ->(message) { targets.include?(session_of.call(message)) }
    end

    # The requests sent from here by the address of NAME that the incarnation NAME opens by id, with where each is.
    def sent_requests(name)
      key, = split(name)
      sent = sees(name, by_id: true, side: :from)
      all_messages.filter_map do |holder, stored|
        request = stored.message
        [holder, request] if request.request? && Store.sender_here(holder, request) == key && sent.call(request)
      end
    end

    private

    # KEY, or KEY/SESSION for one incarnation of the address.
    def split(name)
      key, session = name.to_s.split('/', 2)
      return [key, session] if Address.key?(key) && (session.nil? || Address::SESSION.match?(session))

      raise Error, "invalid name #{name.to_s.inspect}: #{Address::NAME_RULE}"
    end

    def occupant_path(name)
      key, session = split(name)
      return occupant_file(key) if session.nil? || occupant(key)&.session == session

      outgoing_file(key, session)
    end

    def outgoing_file(name, session) = File.join(box(name), OUTGOING, "#{session}.json")
  end
end
