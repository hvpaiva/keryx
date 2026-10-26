# frozen_string_literal: true

require_relative 'address'
require_relative 'error'
require_relative 'files'
require_relative 'store'

module Keryx
  # A message an address sent and where it is: delivered to a mailbox on this machine, with the time its recipient
  # marked it read, or nil while unread, or queued, forwarded or refused in the outbox for another machine.
  SentMessage = Data.define(:message, :delivery, :read_at) do
    def here? = delivery == Archive::DELIVERED
  end

  # The mail of the store as keryx sent reads it, every mailbox on this machine at once, retired ones included, and the
  # outbox. Reading a mailbox here marks, creates and deletes nothing in it.
  class Archive
    include Files

    DELIVERED = 'delivered'

    def initialize(store)
      @store = store
      @problems = store.problems
    end

    # What SENDER, a stable address, sent from here, oldest first: each message it left in a mailbox on this machine,
    # and each the outbox holds for another machine, refused ones included. What a session of SENDER sent counts too.
    def sent_by(sender)
      here = names.flat_map do |name|
        messages(name).filter_map { SentMessage.new(it, DELIVERED, read_at(name, it.id)) if sent?(it, sender) }
      end
      away = outgoing.filter_map { SentMessage.new(it.message, it.state.to_s, nil) if sent?(it.message, sender) }
      (here + away).sort_by { it.message.id }
    end

    private

    def names = @store.address_names

    def outgoing = @store.outbox.outgoing

    def folder(name)
      raise Error, "invalid name #{name.inspect}: MEMBER.TEAM, each #{Address::NAME_RULE}" unless Address.key?(name)

      File.join(@store.root, Store::ADDRESSES, name)
    end

    def messages(name) = messages_in(File.join(folder(name), Store::MAIL))

    # The read mark is a hard link to the message, and making it sets the change time of the file both names share,
    # which nothing keryx does changes after. A copy of the store sets it again, to the time of the copy.
    def read_at(name, id)
      File.lstat(File.join(folder(name), Store::READ, "#{id}.json")).ctime.utc
    rescue Errno::ENOENT
      nil
    end

    def sent?(message, sender) = Address.parse(message.from).stable.to_s == sender
  end
end
