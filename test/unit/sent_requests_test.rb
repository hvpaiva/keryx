# frozen_string_literal: true

require 'test_helper'

class SentRequestsTest < Minitest::Test
  include TempDir
  include Factory

  def store = @store ||= Keryx::Store.new(tmp('state'))

  def test_a_request_was_sent_from_here_when_it_waits_in_the_outbox_or_shares_its_recipients_host
    %w[impl orq].each { store.create_address(it) }
    local = build_message(to: 'impl@lap-0042', from: 'orq@lap-0042', kind: 'request')
    inbound = build_message(to: 'impl@athena', from: 'orq@zeus', kind: 'request')
    note = build_message(to: 'impl@athena', from: 'orq@athena')
    outgoing = build_message(to: 'port@zeus', from: 'orq@lap-0042', kind: 'request')
    [local, inbound, note].each { store.deliver('impl', it) }
    store.outbox.queue('zeus', outgoing)

    assert_equal([['impl', local.id], [nil, outgoing.id]], store.sent_requests('orq').map { [it[0], it[1].id] })
    assert_empty store.sent_requests('impl')
  end
end
