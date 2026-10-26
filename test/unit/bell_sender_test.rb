# frozen_string_literal: true

require 'test_helper'

class BellSenderTest < Minitest::Test
  include TempDir
  include Factory
  include BellHelpers

  # The line herdr types into rev-1.dev's pane for MESSAGES, rung at once.
  def typed_line(*messages)
    store.create_address('rev-1.dev')
    messages.each { store.deliver('rev-1.dev', it) }
    store.bind('rev-1.dev', pane_occupant)
    herdr = herdr_with('idle')

    assert_equal 'rung', bell(herdr:).ring('rev-1.dev', messages).status
    herdr.prompts.first.last
  end

  def request_from(sender) = build_message(to: 'rev-1.dev@athena', from: sender, kind: 'request')

  # What a line for one message says of its sender, between "from" and the full stop before "Run".
  def sender_in(line) = line[/ from (.+)\. Run '/, 1]

  # A session that joined a minute before the messages these tests write, which build_message dates at NOW.
  def holds(name, joined_at: Factory::NOW - 60, **)
    store.create_address(name)
    store.bind(name, build_occupant(joined_at:, **))
  end

  def test_a_person_at_a_terminal_is_named_as_one_on_any_machine
    message = request_from('hvpaiva.local@athena')

    assert_equal '[keryx] New request for rev-1.dev@athena from hvpaiva.local@athena, a person at a terminal. ' \
                 "Run 'keryx read #{message.id}' to open it.", typed_line(message)
    assert_equal 'hvpaiva.local@zeus, a person at a terminal', sender_in(typed_line(request_from('hvpaiva.local@zeus')))
  end

  def test_keryx_s_own_notices_are_named_as_keryx_itself_on_any_machine
    assert_equal 'keryx.system@athena, keryx itself', sender_in(typed_line(request_from('keryx.system@athena')))
    assert_equal 'keryx.system@zeus, keryx itself', sender_in(typed_line(request_from('keryx.system@zeus')))
  end

  def test_an_agent_here_is_named_by_the_harness_of_the_session_that_holds_its_address
    { 'claude' => 'a Claude Code session', 'codex' => 'a Codex session', 'cursor' => 'a Cursor session' }
      .each do |harness, kind|
        holds('orq.dev', harness:)

        assert_equal "orq.dev@athena, #{kind}", sender_in(typed_line(request_from('orq.dev@athena'))), harness
      end
  end

  def test_an_agent_on_another_machine_is_its_address_alone
    holds('orq.dev', harness: 'claude')

    assert_equal 'orq.dev@zeus', sender_in(typed_line(request_from('orq.dev@zeus')))
  end

  def test_an_agent_address_no_session_holds_is_its_address_alone
    store.create_address('orq.dev')

    assert_equal 'orq.dev@athena', sender_in(typed_line(request_from('orq.dev@athena')))
    assert_equal 'gone.dev@athena', sender_in(typed_line(request_from('gone.dev@athena')))
  end

  # created_at keeps whole seconds, so a session that joined within the second the message was written may have taken
  # the address from its writer with join --force.
  def test_the_session_is_named_only_if_it_joined_in_an_earlier_second_than_the_message
    holds('orq.dev', harness: 'codex', joined_at: Factory::NOW - 0.5)

    assert_equal 'orq.dev@athena, a Codex session', sender_in(typed_line(request_from('orq.dev@athena')))

    [Factory::NOW, Factory::NOW + 0.5, Factory::NOW + 1].each do |joined_at|
      holds('orq.dev', harness: 'codex', joined_at:)

      assert_equal 'orq.dev@athena', sender_in(typed_line(request_from('orq.dev@athena'))), joined_at.iso8601(1)
    end
  end

  def test_a_harness_outside_the_table_names_nothing
    holds('orq.dev', harness: 'maki')

    assert_equal 'orq.dev@athena', sender_in(typed_line(request_from('orq.dev@athena')))
  end

  def test_a_damaged_record_of_the_sender_leaves_its_address_alone_and_the_bell_still_rings
    store.create_address('orq.dev')
    File.write(tmp('state', 'addresses', 'orq.dev', 'occupant.json'), '{')

    assert_equal 'orq.dev@athena', sender_in(typed_line(request_from('orq.dev@athena')))
  end

  def test_several_messages_name_what_their_latest_sender_is
    holds('orq.dev', harness: 'claude')
    earlier = request_from('orq.dev@athena')
    latest = build_message(to: 'rev-1.dev@athena', from: 'hvpaiva.local@athena', kind: 'reply')

    assert_equal '[keryx] 2 unread messages for rev-1.dev@athena, the latest a reply from hvpaiva.local@athena, a ' \
                 "person at a terminal. Run 'keryx inbox' to list them.", typed_line(earlier, latest)
  end

  # The channel a bell for MESSAGE took to OCCUPANT at rev-1.dev, and every line that reached a channel. The socket
  # /tmp/gone.sock refuses, and so does the thread named by GONE_THREAD.
  def carried(message, occupant, herdr: FakeHerdr.new, gone_thread: nil)
    sockets = CLIHelpers::FakeClaudeSockets.new.tap { it.gone << '/tmp/gone.sock' }
    queue.queued.clear
    queue.gone.replace([gone_thread].compact)
    store.bind('rev-1.dev', occupant)
    result = bell(herdr:, claude_socket: sockets).ring('rev-1.dev', [message])
    [result.channel, [*sockets.posts, *queue.queued, *herdr.prompts].map(&:last)]
  end

  def test_every_channel_and_its_fallback_carries_the_same_line
    message = request_from('hvpaiva.local@athena')
    store.create_address('rev-1.dev')
    store.deliver('rev-1.dev', message)
    line = '[keryx] New request for rev-1.dev@athena from hvpaiva.local@athena, a person at a terminal. ' \
           "Run 'keryx read #{message.id}' to open it."
    codex = pane_occupant(harness: 'codex', session_id: 'thread-1')
    codex_pane = -> { herdr_with('working', kind: 'codex', session: 'thread-1') }

    assert_equal({ claude: ['claude', [line]], claude_to_herdr: ['herdr', [line]], codex: ['codex', [line]],
                   codex_to_herdr: ['herdr', [line]], herdr: ['herdr', [line]] },
                 { claude: carried(message, build_occupant(claude_socket: '/tmp/cc.sock')),
                   claude_to_herdr: carried(message, pane_occupant(harness: 'claude', claude_socket: '/tmp/gone.sock'),
                                            herdr: herdr_with('idle', kind: 'claude')),
                   codex: carried(message, codex, herdr: codex_pane.call),
                   codex_to_herdr: carried(message, codex, herdr: codex_pane.call, gone_thread: 'thread-1'),
                   herdr: carried(message, pane_occupant, herdr: herdr_with('idle')) })
  end
end
