# frozen_string_literal: true

require_relative '../cli/command'
require_relative 'join'

module Keryx
  module Commands
    class Retire < CLI::Command
      define 'retire', section: 'Session Commands', arguments: 'ADDRESS', min: 1, max: 1,
                       summary: 'Retire an address that nobody holds and nobody waits on',
                       description: "Retire an address whose work is done, so that it takes no new mail.\n\n" \
                                    'keryx refuses while a live session holds the address, which that session ' \
                                    "releases with 'keryx leave', and while a request sent to it waits for its " \
                                    'answer or one it sent waits for a reply. The refusal names each request and ' \
                                    "the command that settles it, such as 'keryx reply ID --as ADDRESS'. A " \
                                    'session that join --force displaced from the address holds it too until it ' \
                                    "leaves.\n\n#{ADDRESS_FORMS} retire takes only the address itself, and " \
                                    'refuses ADDRESS/SESSION, one session of it, with the address to give ' \
                                    "instead.\n\n" \
                                    'Once retired, the address is gone from keryx who and keryx status, even with ' \
                                    '--all, new mail to it is refused, from this machine and from others, and no ' \
                                    'command acts as it with --as, though keryx history ADDRESS still lists its ' \
                                    'mail, and with --sent what it sent. A request that reached it as it was retired ' \
                                    'stays open for its sender, and the withdrawal of that request still reaches ' \
                                    'it, from here or from another machine, so its sender stops waiting. Its ' \
                                    'files stay where they were, under ' \
                                    'addresses/MEMBER.TEAM in the keryx state directory, until keryx purge removes ' \
                                    'its mail, and ' \
                                    "'keryx join MEMBER.TEAM --revive' " \
                                    "brings it back with its mailbox as it was.\n\n" \
                                    'An address is retired on the machine that has it, since only that machine ' \
                                    'sees its session and its mail.',
                       examples: [['Retire the address of a reviewer whose session ended', 'retire rev-1.alpha'],
                                  ['Take it back later', 'join rev-1.alpha --revive']]

      def call(arguments)
        name = local_name(arguments.first)
        refuse_person(name)
        raise Error, "no address #{app.full(name)}" unless app.store.address?(name)

        by = app.full(app.me)
        app.store.with_occupants_lock { retire(name, by) }
        report(name)
      end

      private

      def local_name(text)
        address = app.address(text)
        if address.session
          raise Error, "#{address} is one session of #{address.stable}, and retire takes only the address itself"
        end
        return address.key if address.local?(app.host)

        raise Error, "retire runs on the machine that holds the address; run 'keryx retire #{address.key}' on " \
                     "#{address.host}"
      end

      def refuse_person(name)
        return unless name == app.identity.human_name

        raise Error, "#{app.full(name)} is the address a plain terminal on #{app.host} acts as, so it cannot be retired"
      end

      # The checks and the record share one hold of the occupants lock, so no join comes in between.
      def retire(name, by)
        refuse_retired(name)
        refuse_held(name)
        refuse_waiting(name)
        app.store.retire(name, by:, now: app.now)
      end

      def refuse_retired(name)
        record = app.store.retired(name) or return

        raise Error, "#{app.full(name)} is retired already, since " \
                     "#{record.retired_at.utc.strftime('%Y-%m-%d %H:%M:%S UTC')} by #{record.by}"
      end

      def refuse_held(name)
        app.store.incarnations(name).each do |incarnation|
          occupant = app.store.occupant(incarnation)
          if occupant && app.caller.holds?(occupant)
            raise Error, "this session holds #{app.full(incarnation)}; release it with 'keryx leave' first"
          end

          Join.refuse_taken(app, incarnation, "that session releases it with 'keryx leave', and once it ends " \
                                              "'keryx retire #{name}' works")
        end
      end

      def refuse_waiting(name)
        received, sent = app.roster.waiting(name)
        count = received.size + sent.size
        return if count.zero?

        raise Error, "#{app.full(name)} has #{count} open request#{'s' unless count == 1} and retires once none is " \
                     "left: #{(received.map { answer(name, it) } + sent.map { withdraw(name, it) }).join('; ')}"
      end

      def report(name)
        files = Text.plain(File.join(app.store.root, Store::ADDRESSES, name))
        terminal.puts("Retired #{terminal.paint(:address, app.full(name))}. Its files stay in #{files}, and " \
                      "'keryx join #{name} --revive' brings it back with its mailbox.")
        nil
      end

      def answer(name, request)
        "#{request.id} from #{request.from} waits for its answer ('keryx reply #{request.id} --as #{name}', or its " \
          'sender withdraws it)'
      end

      def withdraw(name, request)
        "#{request.id} it sent to #{request.to} waits for a reply ('keryx withdraw #{request.id} --as #{name}')"
      end
    end
  end
end
