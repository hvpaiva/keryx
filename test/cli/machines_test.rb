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

  def test_a_read_and_a_queued_reply_show_only_on_the_machine_where_they_happen
    keryx('ask', 'port@zeus', 'Port it', env: @orq)
    id = last_id(@port)
    keryx('read', id, env: @port)
    open = lambda do |env|
      JSON.parse(keryx('status', '-o', 'json', env:).out)['open_requests'].to_h { it.values_at('id', 'state') }
    end

    assert_equal [{ id => 'forwarded' }, { id => 'read' }], [open.call({}), open.call(@port)]
    remote.down << 'athena'
    keryx('reply', id, 'Done', env: @port)

    assert_equal [{ id => 'forwarded' }, {}], [open.call({}), open.call(@port)]
  end

  def test_a_machine_that_is_down_gets_the_message_once_it_is_back
    remote.down << 'zeus'
    sent = keryx('send', 'port@zeus', 'Are you there?', env: @orq)
    queued = JSON.parse(keryx('status', '-o', 'json').out)['not_forwarded']

    assert_match(/zeus did not answer \(ssh: connect to host zeus .*\); the message waits in the outbox/, sent.out)
    assert_equal([['port@zeus', 'queued', 1]], queued.map { it.values_at('to', 'state', 'attempts') })
    assert_match(/\A1 message\(s\) wait for zeus: ssh: connect to host zeus/, keryx('courier', '--once').out)
    remote.down.clear

    assert_match(/\Aforwarded \w+ to zeus\n/, keryx('courier', '--once').out)
    assert_equal ['Are you there?'], bodies(@port)
    assert_empty JSON.parse(keryx('status', '-o', 'json').out)['not_forwarded']
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

  def test_a_line_with_a_field_of_the_wrong_type_does_not_stop_the_batch
    bad = JSON.parse(build_message(to: 'port@zeus', from: 'orq@athena').to_json).merge('from' => 42)
    good = build_message(to: 'port@zeus', from: 'orq@athena', body: 'still here')
    out = keryx('__receive', env: machine('zeus'), input: "#{JSON.generate(bad)}\n#{good.to_json}\n").out

    assert_equal(%w[refused delivered], out.lines.map { JSON.parse(it)['status'] })
    assert_equal ['still here'], bodies(@port)
  end

  def test_the_courier_rings_a_session_that_joined_after_the_message
    keryx('leave', env: @port)
    keryx('send', 'port@zeus', 'Waiting for you', env: @orq)
    alive << 444
    keryx('join', 'port', env: machine('zeus').merge(claude(444)))

    assert_match(/\Arang port@zeus: rung\n/, keryx('courier', '--once', env: machine('zeus')).out)
    assert_equal '/tmp/cc-444.sock', sockets.posts.last.first
    assert_empty keryx('courier', '--once', env: machine('zeus')).out
  end

  def test_the_courier_tells_the_sender_once_when_a_deadline_passes
    keryx('ask', 'port@zeus', 'Port it', '--within', '1m', env: @orq)
    clock.advance(120)

    assert_match(/\Atold orq@athena that \w+ to port@zeus is past its deadline\n/, keryx('courier', '--once').out)
    notice = JSON.parse(keryx('inbox', '-o', 'json', env: @orq).out).first

    assert_equal 'keryx@athena', notice['from']
    assert_match(/\ARequest \w+ to port@zeus passed its deadline without a reply\.\z/, notice['body'])
    assert_empty keryx('courier', '--once').out
  end
end
