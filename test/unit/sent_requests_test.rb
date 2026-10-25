# frozen_string_literal: true

require 'test_helper'

class SentRequestsTest < Minitest::Test
  include TempDir
  include Factory

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def test_a_request_was_sent_from_here_when_it_waits_in_the_outbox_or_shares_its_recipients_host
    %w[impl.dev orq.dev].each { store.create_address(it) }
    local = build_message(to: 'impl.dev@lap-0042', from: 'orq.dev@lap-0042', kind: 'request')
    inbound = build_message(to: 'impl.dev@athena', from: 'orq.dev@zeus', kind: 'request')
    note = build_message(to: 'impl.dev@athena', from: 'orq.dev@athena')
    outgoing = build_message(to: 'port.dev@zeus', from: 'orq.dev@lap-0042', kind: 'request')
    [local, inbound, note].each { store.deliver('impl.dev', it) }
    store.outbox.queue('zeus', outgoing)

    assert_equal([['impl.dev', local.id], [nil, outgoing.id]], store.sent_requests('orq.dev').map { [it[0], it[1].id] })
    assert_empty store.sent_requests('impl.dev')
  end
end
