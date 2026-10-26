# frozen_string_literal: true

require_relative 'address'
require_relative 'bell'
require_relative 'dialog'
require_relative 'error'
require_relative 'identity'
require_relative 'retirement'
require_relative 'store'
require_relative 'ulid'

module Keryx
  # The courier's step that tells the director of a joined session when its herdr pane shows a dialog. A dialog is
  # told once, a new one in the same pane is told again, and so is the same one once a read showed the pane free of
  # it, such as the same permission question asked a second time. keryx never answers one.
  class DialogNotice
    Told = Data.define(:name, :recipient, :pane)
    # A session whose pane the round read, the director it tells, the mark of its record for that join and that record
    # as the round read it before the pane, or nil for none.
    Seen = Data.define(:name, :occupant, :recipient, :mark, :record) do
      def pane = occupant.herdr_pane
    end
    NAME = Identity::SYSTEM
    # The record of the dialog last told for a join and a recipient, its key and the id its notice took.
    SHOWN = 'dialog-shown'
    # The notice's mark, written once after the post, so only the courier that writes it reports the notice.
    TOLD = 'dialog'
    RECORD = /\A(?<key>\h{64}) (?<id>\S+)\z/

    def initialize(store:, herdr:, postman:, host:, clock:, errors:)
      @store = store
      @herdr = herdr
      @postman = postman
      @host = host
      @clock = clock
      @errors = errors
    end

    # A pane herdr does not read, a screen too narrow to tell and a queued message being edited tell nothing and keep
    # the record, since none of them shows that the dialog told before is gone. Only a screen with no obstacle clears
    # it.
    def tell(name, occupant, recipient)
      seen = seen(name, occupant, recipient) or return
      read = @herdr.visible(occupant.herdr_socket, occupant.herdr_pane) or return
      obstacle = Bell.obstacle(read)
      return clear(seen) if obstacle.nil?

      quote = Dialog.shown(read) if obstacle == :dialog
      notify(seen, quote) if quote
    end

    private

    # The record is read before the pane, for the hold that changes it to compare; see unchanged?.
    def seen(name, occupant, recipient)
      mark = Ulid.derive(occupant.joined_at, "dialog #{recipient} #{Courier.join_of(occupant)}")
      Seen.new(name:, occupant:, recipient:, mark:, record: @store.claimed(name, mark, SHOWN))
    rescue Error, SystemCallError => e
      @errors << "could not read the dialog record of #{full(name)}; #{e.message}"
      nil
    end

    def notify(seen, quote)
      key = Dialog.key(quote)
      return if told?(seen, key)
      return retired(seen, key) if seen.recipient.local?(@host) && @store.retired?(seen.recipient.key)

      post(seen, key, body(seen, quote))
    rescue Error, SystemCallError => e
      @errors << "could not tell #{about(seen)}; #{e.message}"
      nil
    end

    def told?(seen, key)
      shown = parse(seen.record)
      shown&.first == key && @store.marked?(seen.name, shown.last, TOLD)
    end

    # The claim runs in the post's hold of the occupants lock, so of the couriers that found the same dialog untold only
    # the first to claim posts it, a courier that posts it after one stopped before its mark uses the id that one
    # wrote, and the store keeps one copy.
    def post(seen, key, body)
      id = nil
      claim = -> { id = claim(seen, key) }
      return unless @postman.post(sender: NAME, recipient: seen.recipient, kind: 'message', body:, claim:)
      return unless @store.mark_once(seen.name, id, TOLD)

      Told.new(name: seen.name, recipient: seen.recipient.to_s, pane: seen.pane)
    end

    # The id the record holds for this dialog, or a fresh one written over a record of another dialog, and none once
    # another session joined the address or the record changed since the round read it.
    def claim(seen, key)
      return unless Courier.same_join?(@store.occupant(seen.name), seen.occupant) && unchanged?(seen)

      shown = shown(seen)
      return shown.last if shown&.first == key

      Ulid.generate(@clock.call).tap { @store.reclaim(seen.name, seen.mark, SHOWN, "#{key} #{it}") }
    end

    # Every change to the record is made in a hold of the occupants lock, so a hold that finds it as the round read it
    # knows that no courier changed it since. One that finds it changed changes nothing, since the round's read of the
    # pane may be older than the change, and the next round reads both again.
    def unchanged?(seen) = @store.claimed(seen.name, seen.mark, SHOWN) == seen.record

    # The key and id the record holds, or nil. A damaged record is a problem and an error of the round, said by the
    # read in the lock that writes over it.
    def shown(seen)
      parse(@store.claimed(seen.name, seen.mark, SHOWN) { parse(it) })
    rescue Store::Damaged => e
      @store.problems << e.message
      @errors << "the dialog notice of #{full(seen.name)} writes over its damaged record; #{e.message}"
      nil
    end

    # A recipient here that is retired takes no mail, so the dialog counts as told, and the courier that marks it says
    # once that it did not tell it.
    def retired(seen, key)
      id = @store.with_occupants_lock { claim(seen, key) } or return
      return unless @store.mark_once(seen.name, id, TOLD)

      @errors << "did not tell #{about(seen)}; #{format(Retirement::RETIRED, seen.recipient)}"
      nil
    end

    # A pane with no dialog and no record read before it takes no lock.
    def clear(seen)
      return unless seen.record

      @store.with_occupants_lock { @store.unmark(seen.name, seen.mark, SHOWN) if unchanged?(seen) }
      nil
    rescue Error, SystemCallError => e
      @errors << "could not clear the dialog record of #{full(seen.name)}; #{e.message}"
      nil
    end

    # The key and id of RECORD, or nil for none or one that does not parse.
    def parse(record)
      found = RECORD.match(record.to_s) or return
      [found[:key], found[:id]] if Ulid.valid?(found[:id])
    end

    def about(seen) = "#{seen.recipient} about the dialog in pane #{seen.pane} of #{full(seen.name)}"

    def body(seen, quote)
      "#{full(seen.name)} stops at a dialog in pane #{seen.pane} and waits until it is answered. Its text " \
        "follows.\n\n#{quote.map { "  #{it}" }.join("\n")}\n\n#{format(Dialog::ANSWER, pane: seen.pane)} keryx " \
        'tells you again only when the pane shows a new dialog.'
    end

    def full(name) = Address.from_name(name, host: @host)
  end
end
