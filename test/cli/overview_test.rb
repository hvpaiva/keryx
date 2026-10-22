# frozen_string_literal: true

require 'test_helper'

class OverviewTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def setup
    super
    @orq = join_claude('orq', 111, role: 'orchestrator')
    @rev = join_claude('rev-1', 222, role: 'reviewer')
  end

  def section(output, title)
    output.split("\n\n").find { it.start_with?(title) }.lines.drop(1).map { it.split(/ {3,}/).map(&:strip) }
  end

  def test_status_shows_addresses_open_requests_and_unrung_bells
    keryx('ask', 'rev-1', 'Review PR #448', '--within', '10m', env: @orq)
    sockets.gone << '/tmp/cc-111.sock'
    keryx('send', 'orq', 'heads-up', env: @rev)
    clock.advance(900)
    output = keryx('status').out

    assert_equal [%w[ADDRESS ROLE SESSION UNREAD WAITING], %w[orq@athena orchestrator live 1 0],
                  %w[rev-1@athena reviewer live 1 1]], section(output, 'ADDRESSES')
    assert_equal ['orq@athena', 'rev-1@athena', '15m', 'overdue 5m', 'unread', 'Review PR #448'],
                 section(output, 'OPEN REQUESTS')[1][1..]
    assert_equal %w[orq@athena rev-1@athena failed], section(output, 'NOT RUNG')[1][1..3]
  end

  def test_a_reply_closes_the_request
    keryx('ask', 'rev-1', 'Review PR #448', env: @orq)
    keryx('reply', last_id(@rev), 'Done', env: @rev)
    data = JSON.parse(keryx('status', '-o', 'json').out)

    assert_empty data['open_requests']
    assert_equal([0, 0], data['addresses'].map { it['waiting'] })
  end

  def test_a_read_request_without_a_reply_stays_open
    keryx('ask', 'rev-1', 'Review PR #448', env: @orq)
    keryx('read', env: @rev)

    assert_equal(['read'], JSON.parse(keryx('status', '-o', 'json').out)['open_requests'].map { it['state'] })
  end

  def test_status_takes_a_damaged_bell_receipt_for_a_bell_never_rung
    keryx('send', 'rev-1', 'hello', env: @orq)
    id = last_id(@rev)
    File.write(tmp('state', 'addresses', 'rev-1', 'receipts', "#{id}.bell"), '[]')
    result = keryx('status', '-o', 'json')

    assert_equal 0, result.status
    assert_equal([[id, 'none']], JSON.parse(result.out)['not_rung'].map { it.values_at('id', 'bell') })
    assert_match(/#{id}\.bell is not a JSON object; it is ignored until keryx writes it again/, result.err)
  end

  def test_status_with_nothing_pending
    sections = keryx('status').out

    assert_match(/OPEN REQUESTS\nnone/, sections)
    assert_match(/NOT RUNG\nnone/, sections)
  end

  def test_ring_retries_the_bells_that_did_not_reach_a_session
    sockets.gone << '/tmp/cc-222.sock'
    keryx('send', 'rev-1', 'one', env: @orq)
    clock.advance(1)
    keryx('send', 'rev-1', 'two', env: @orq)
    sockets.gone.clear
    result = keryx('ring')

    assert_match(/\Arev-1@athena +2 unread +rung via claude\n\z/, result.out)
    assert_match(/\[keryx\] 2 unread messages for rev-1@athena/, sockets.posts.last.last)
    assert_empty JSON.parse(keryx('status', '-o', 'json').out)['not_rung']
  end

  def test_ring_names_addresses_and_says_when_nothing_is_pending
    assert_equal "Nothing to ring: no address has unread messages.\n", keryx('ring').out
    assert_match(/no address ghost@athena/, keryx('ring', 'ghost').err)
    assert_match(/on another machine/, keryx('ring', 'rev-1@zeus').err)
  end
end
