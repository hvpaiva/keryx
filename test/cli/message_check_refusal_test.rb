# frozen_string_literal: true

require 'test_helper'

# A message athena's checker refuses is written nowhere, queued nowhere and rings nothing, and the sender reads the
# checker's own words.
class MessageCheckRefusalTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include MessageCheckHelpers

  def setup
    super
    @orq = join_claude('orq.dev', 111)
    @rev = join_claude('rev-1.dev', 222)
  end

  # orq asked rev-1.dev before the refusing check was written, and that bell is forgotten.
  def asked
    must(keryx('ask', 'rev-1.dev', 'Review PR #448', env: @orq))
    clock.advance(1)
    sockets.posts.clear
    store.unread('rev-1.dev').first.id
  end

  def kinds(name) = store.stored(name).map { it.message.kind }

  def test_a_refused_send_reaches_no_mailbox
    refusing(reason: "subject line missing\n\tsee CONTRIBUTING.md")
    sent = keryx('send', 'rev-1.dev', 'A note', env: @orq)

    assert_refused(sent, "subject line missing\n\tsee CONTRIBUTING.md")
    assert_empty kinds('rev-1.dev')
    assert_equal 'send', envelopes.first['command']
  end

  def test_a_refused_ask_reaches_no_mailbox_and_opens_no_request
    refusing
    asked = keryx('ask', 'rev-1.dev', 'Review it', env: @orq)

    assert_refused(asked)
    assert_empty kinds('rev-1.dev')
    assert_empty open_requests
  end

  def test_a_refused_send_re_leaves_the_request_unread_and_untaken
    id = asked
    refusing
    sent = keryx('send', '--re', id, 'On it', env: @rev)

    assert_refused(sent)
    assert_empty kinds('orq.dev')
    assert_equal [id], store.unread('rev-1.dev').map(&:id)
  end

  def test_a_refused_send_on_adds_nothing_to_the_request
    id = asked
    refusing
    sent = keryx('send', '--on', id, 'The fixture is reset', env: @orq)

    assert_refused(sent)
    assert_equal %w[request], kinds('rev-1.dev')
    assert_equal [id], open_requests
  end

  def test_a_refused_reply_leaves_the_request_open_and_unread
    id = asked
    refusing
    replied = keryx('reply', id, 'Approved', env: @rev)

    assert_refused(replied)
    assert_empty kinds('orq.dev')
    assert_equal [id], open_requests
    assert_equal [id], store.unread('rev-1.dev').map(&:id)
  end

  def test_a_refused_withdrawal_leaves_the_request_open
    id = asked
    refusing
    withdrew = keryx('withdraw', id, 'Fixed upstream', env: @orq)

    assert_refused(withdrew)
    assert_equal %w[request], kinds('rev-1.dev')
    assert_equal [id], open_requests
  end

  def test_a_checker_that_says_nothing_still_refuses
    check_with(checker('athena', status: 1))
    sent = keryx('send', 'rev-1.dev', 'A note', env: @orq)

    assert_equal [1, '', "error: the check refused the message and gave no reason\n"],
                 [sent.status, sent.out, sent.err]
    assert_empty kinds('rev-1.dev')
  end
end
