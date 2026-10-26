# frozen_string_literal: true

require 'test_helper'

class SendOnTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def setup
    super
    @orq = join_claude('orq.dev', 111)
    @rev = join_claude('rev-1.dev', 222)
    keryx('ask', 'rev-1.dev', 'Review PR #448', env: @orq)
    @id = last_id(@rev)
    clock.advance(1)
  end

  def states = JSON.parse(keryx('status', '-o', 'json').out)['open_requests'].to_h { it.values_at('id', 'state') }

  def inbox(env) = JSON.parse(keryx('inbox', '--all', '-o', 'json', env:).out)

  def test_send_on_adds_to_the_request_without_taking_or_reading_it
    sent = keryx('send', '--on', @id, 'The fixture is reset', env: @orq)
    message = inbox(@rev).last

    assert_equal 0, sent.status, sent.err
    assert_match(/\ASent \w{26} to rev-1.dev@athena in the thread of #{@id}\. The bell rang through claude\.\n\z/,
                 sent.out)
    assert_equal ['message', @id, @id, 'orq.dev@athena', 'rev-1.dev@athena', 'The fixture is reset'],
                 message.values_at('kind', 'thread', 'in_reply_to', 'from', 'to', 'body')
    assert_equal({ @id => 'unread' }, states)
    assert_empty inbox(@orq)
    assert_equal(%w[request message], inbox(@rev).map { it['kind'] })
  end

  def test_a_later_reply_still_answers_the_original_request
    keryx('send', '--on', @id, 'The fixture is reset', env: @orq)
    keryx('reply', @id, 'Approved', env: @rev)

    assert_empty states
  end

  def test_send_on_refuses_a_request_somebody_else_sent
    result = keryx('send', '--on', @id, 'Mine', env: @rev)

    assert_equal 1, result.status
    assert_match(/no request #{@id} sent by rev-1.dev@athena/, result.err)
    assert_equal(%w[request], inbox(@rev).map { it['kind'] })
  end

  def test_send_on_refuses_a_request_already_answered
    replied = keryx('reply', @id, 'Approved', env: @rev).out[/\w{26}/]
    result = keryx('send', '--on', @id, 'More', env: @orq)

    assert_equal 1, result.status
    assert_match(/#{@id} is already answered by #{replied}; .*'keryx send ADDRESS'/, result.err)
  end

  def test_send_on_refuses_a_withdrawn_request
    keryx('withdraw', @id, env: @orq)
    withdrawal = last_id(@rev)
    result = keryx('send', '--on', @id, 'More', env: @orq)

    assert_equal 1, result.status
    assert_match(/#{@id} is withdrawn by #{withdrawal}; .*'keryx send ADDRESS'/, result.err)
  end

  def test_send_on_refuses_the_other_thread_flag_and_an_address
    both = keryx('send', '--on', @id, '--re', @id, 'More', env: @orq)
    addressed = keryx('send', '--on', @id, 'rev-1.dev', 'More', env: @orq)

    assert_equal 2, both.status
    assert_match(/--on and --re send in different directions; use only one/, both.err)
    assert_equal 2, addressed.status
    assert_match(/--on sends to the request's recipient; leave out ADDRESS/, addressed.err)
    assert_equal(%w[request], inbox(@rev).map { it['kind'] })
  end

  def test_send_on_refuses_a_message_that_is_not_a_request
    keryx('send', 'rev-1.dev', 'A note', env: @orq)
    note = last_id(@rev)
    clock.advance(1)
    result = keryx('send', '--on', note, 'More', env: @orq)

    assert_equal 1, result.status
    assert_match(/no request #{note} sent by orq.dev@athena/, result.err)
    assert_equal(%w[request message], inbox(@rev).map { it['kind'] })
  end

  def test_send_on_reaches_the_recipient_here_of_a_request_from_before_the_machine_was_renamed
    keryx('ask', 'rev-1.dev', 'Port it', env: @orq.merge('KERYX_HOST' => 'lap-0042'))
    id = last_id(@rev)
    clock.advance(1)
    remote.down << 'lap-0042'
    sent = keryx('send', '--on', id, 'The fixture is reset', env: @orq)

    assert_equal 0, sent.status, sent.err
    assert_match(/\ASent \w{26} to rev-1.dev@athena in the thread of #{id}\. The bell rang through claude\.\n\z/,
                 sent.out)
    assert_equal ['message', id, id, 'orq.dev@athena', 'rev-1.dev@athena', 'The fixture is reset'],
                 inbox(@rev).last.values_at('kind', 'thread', 'in_reply_to', 'from', 'to', 'body')
    assert_empty store.outbox.outgoing('lap-0042')
  end

  def test_send_on_refuses_a_request_to_ones_own_address
    keryx('ask', 'orq.dev', 'Remember the release notes', env: @orq)
    id = last_id(@orq)
    clock.advance(1)
    result = keryx('send', '--on', id, 'And the changelog', env: @orq)

    assert_equal 1, result.status
    assert_equal "error: #{id} is a request to your own address, so there is no one to add to; answer it with " \
                 "'keryx reply #{id}' or close it with 'keryx withdraw #{id}'\n", result.err
    assert_equal(%w[request], inbox(@orq).map { it['kind'] })
    assert_equal ['unread', :unread], [states.fetch(id), store.find('orq.dev', id).state]
  end

  def test_the_skill_tells_the_sender_how_to_add_to_a_request
    assert_includes keryx('skill').out, 'keryx send --on ID TEXT'
  end
end

class SendOnRemoteTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def setup
    super
    @orq = join_claude('orq.dev', 111)
    alive << 333
    @port = machine('zeus').merge(claude(333))
    result = keryx('join', 'port.dev', env: @port)
    raise "join failed: #{result.err}" unless result.status.zero?
  end

  def states(env)
    JSON.parse(keryx('status', '-o', 'json', env:).out)['open_requests'].to_h { it.values_at('id', 'state') }
  end

  def test_send_on_reaches_the_other_machine_in_the_same_thread
    keryx('ask', 'port.dev@zeus', 'Port it', env: @orq)
    id = last_id(@port)
    before = [states({}), states(@port)]
    clock.advance(1)
    sent = keryx('send', '--on', id, 'Also cover the tests', env: @orq)
    messages = JSON.parse(keryx('inbox', '--all', '-o', 'json', env: @port).out)
    message = messages.find { it['kind'] == 'message' }

    assert_equal 0, sent.status, sent.err
    assert_match(/\ASent \w{26} to port.dev@zeus in the thread of #{id}\. It reached zeus\. /, sent.out)
    assert_match(/The bell rang through claude\.\n\z/, sent.out)
    assert_equal(%w[request message], messages.map { it['kind'] })
    assert_equal ['message', id, id, 'orq.dev@athena', 'Also cover the tests'],
                 message.values_at('kind', 'thread', 'in_reply_to', 'from', 'body')
    assert_equal before, [states({}), states(@port)]
  end
end
