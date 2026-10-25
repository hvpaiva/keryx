# frozen_string_literal: true

# Addresses as a keryx from before team names left them, for tests that include CLIHelpers.
module FlatAddresses
  # Gives an address the flat name and the record a keryx from before team names wrote, and returns that name.
  def flatten(key, state: tmp('state'))
    name = key.split('.').first
    File.rename(File.join(state, 'addresses', key), File.join(state, 'addresses', name))
    File.write(File.join(state, 'addresses', name, 'address.json'),
               JSON.generate('name' => name, 'created_at' => Factory::NOW.iso8601))
    name
  end

  # An address as a keryx from before team names left it, with no session holding it.
  def unheld(name)
    store.create_address("#{name}.old")
    flatten("#{name}.old")
  end

  # A session that joined NAME before team names, holding it still.
  def held(name, pid)
    env = join_claude("#{name}.dev", pid)
    flatten("#{name}.dev")
    env
  end

  def flat_request(from:, to:)
    build_message(from:, to:, kind: 'request', body: 'Review PR #448', id: Keryx::Ulid.generate(Factory::NOW))
  end

  # On zeus, port@zeus asked orq@athena for a review before team names, and holds a request orq@athena sent it.
  def flat_threads_on_zeus
    alive << 333
    keryx('join', 'port.dev', env: machine('zeus').merge(claude(333)))
    flatten('port.dev', state: tmp('zeus'))
    zeus = Keryx::Store.new(tmp('zeus'))
    [flat_request(from: 'port@zeus', to: 'orq@athena').tap { zeus.outbox.queue('athena', it) },
     flat_request(from: 'orq@athena', to: 'port@zeus').tap { zeus.deliver('port', it) }]
  end

  # The refusal of mail to ADDRESS, or from it when SENDS, with the request that is OVER when that is why.
  def flat_refusal(address, over: nil, sends: false)
    rule = "#{address} is an address from before team names: it #{sends ? 'sends' : 'takes'} only replies, " \
           'withdrawals and messages in its open threads'
    over ? "request #{over} is over, and #{rule}" : rule
  end
end
