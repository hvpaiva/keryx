# frozen_string_literal: true

require 'test_helper'

class MachinesTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def setup
    super
    @orq = join_claude('orq', 111)
    alive << 333
    @port = machine('zeus').merge(claude(333))
    result = keryx('join', 'port', env: @port)
    raise "join failed: #{result.err}" unless result.status.zero?
  end

  def bodies(env) = JSON.parse(keryx('inbox', '-o', 'json', env:).out).map { it['body'] }

  def test_a_request_reaches_the_other_machine_and_its_reply_comes_back
    asked = keryx('ask', 'port@zeus', 'Port retry.py to Go', '--within', '30m', env: @orq)
    id = last_id(@port)

    assert_match(/\AAsked port@zeus \(#{id}\)\. It reached zeus\. The bell rang through claude\./, asked.out)
    assert_equal '/tmp/cc-333.sock', sockets.posts.last.first
    replied = keryx('reply', id, 'Done in retry.go', env: @port)

    assert_match(/\AReplied to orq@athena \(\w+\)\. It reached athena\. The bell rang through claude\./, replied.out)
    assert_equal '/tmp/cc-111.sock', sockets.posts.last.first
    assert_equal ['Done in retry.go'], bodies(@orq)
  end

  def test_both_machines_list_the_request_as_open_until_the_reply
    keryx('ask', 'port@zeus', 'Port it', env: @orq)
    id = last_id(@port)
    open = ->(env) { JSON.parse(keryx('status', '-o', 'json', env:).out)['open_requests'].map { it['id'] } }

    assert_equal [[id], [id]], [open.call({}), open.call(@port)]
    keryx('reply', id, 'Done', env: @port)

    assert_equal [[], []], [open.call({}), open.call(@port)]
  end

  def test_a_message_that_arrives_twice_is_stored_once
    line = "#{build_message(to: 'port@zeus', from: 'orq@athena').to_json}\n"
    receipts = Array.new(2) { JSON.parse(keryx('__receive', env: machine('zeus'), input: line).out) }

    assert_equal(%w[delivered duplicate], receipts.map { it['status'] })
    assert_equal ['hello'], bodies(@port)
  end

  def test_receive_refuses_what_does_not_belong_on_this_machine
    lines = [build_message(to: 'port@athena', from: 'orq@athena'), build_message(to: 'port@zeus', from: 'eve@zeus'),
             build_message(to: 'ghost@zeus', from: 'orq@athena')].map { "#{it.to_json}\n" }.join
    receipts = keryx('__receive', env: machine('zeus'), input: "#{lines}not json\n").out.lines.map { JSON.parse(it) }

    assert_equal(%w[refused] * 4, receipts.map { it['status'] })
    assert_equal(['port@athena is not on zeus', 'eve@zeus is on zeus and cannot arrive from another machine',
                  'no address ghost@zeus'], receipts.first(3).map { it['detail'] })
    assert_empty bodies(@port)
  end
end
