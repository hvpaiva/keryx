# frozen_string_literal: true

require_relative 'address'
require_relative 'error'
require_relative 'files'
require_relative 'message'
require_relative 'store'

module Keryx
  # A message an address sent and where it is: delivered to a mailbox on this machine, with the time its recipient
  # marked it read, or nil while unread, or queued, forwarded or refused in the outbox for another machine.
  SentMessage = Data.define(:message, :delivery, :read_at) do
    def here? = delivery == Archive::DELIVERED
  end

  # The mail of the store as keryx sent and keryx history read it, every mailbox on this machine at once, retired ones
  # included, and the outbox. Reading a mailbox here marks, creates and deletes nothing in it.
  class Archive
    include Files

    DELIVERED = 'delivered'

    # OLD is the reading keryx history makes. A folder from before team names, addresses/NAME with no dot, counts too,
    # by its NAME alone, apart from Store, which never takes one, and a message of format 1 reads there and in the
    # outbox's cur/ and refused/.
    def initialize(store, old: false)
      @store = store
      @root = store.root
      @old = old
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

    # Every message the mailbox of NAME holds, read and unread, oldest first.
    def held(name)
      read = ids_in(File.join(folder(name), Store::READ)).to_set
      messages(name).map { StoredMessage.new(it, read.include?(it.id) ? :read : :unread) }
    end

    # Whether NAME is a folder from before team names, which only the reading keryx history makes takes.
    def old?(name) = @old && Address::NAME.match?(name.to_s) && stored_file?(File.join(folder(name), 'address.json'))

    private

    def names = @old ? [*@store.address_names, *old_names] : @store.address_names

    def old_names
      base = File.join(@store.root, Store::ADDRESSES)
      stored_folder?(base) ? Dir.children(base).select { old?(it) }.sort : []
    end

    def outgoing = @old ? @store.outbox.outgoing(read: method(:messages_in)) : @store.outbox.outgoing

    def folder(name)
      unless Address.key?(name) || (@old && Address::NAME.match?(name.to_s))
        raise Error, "invalid name #{name.inspect}: MEMBER.TEAM, each #{Address::NAME_RULE}"
      end

      File.join(@store.root, Store::ADDRESSES, name)
    end

    def messages(name) = messages_in(File.join(folder(name), Store::MAIL))

    # The read mark is a hard link to the message, and making it sets the change time of the file both names share,
    # which nothing keryx does changes after. A copy of the store sets it again, to the time of the copy. A read/ behind
    # a symbolic link holds no mark of this store.
    def read_at(name, id)
      read = File.join(folder(name), Store::READ)
      File.lstat(File.join(read, "#{id}.json")).ctime.utc unless first_link(read)
    rescue Errno::ENOENT
      nil
    end

    def sent?(message, sender) = Address.parse(message.from).stable.to_s == sender

    # Files#load_message, which takes format 1 too in the reading keryx history makes.
    def load_message(path)
      return super unless @old

      text = read_regular(path, File::NOFOLLOW) or raise Error, 'not a regular file'
      message = Message.from_json(text, old_format: true)
      return message if File.basename(path, '.json') == message.id

      raise Error, "the file name does not match the message id #{message.id}"
    end
  end
end
