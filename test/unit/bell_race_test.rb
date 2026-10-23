# frozen_string_literal: true

require 'test_helper'

class BellRaceTest < Minitest::Test
  include TempDir
  include Factory
  include BellHelpers

  def ring_while_the_screen_is_read(herdr, occupant: pane_occupant, &change)
    message = deliver
    store.bind('rev-1', occupant)
    herdr.on_screen = change
    bell(herdr:).ring('rev-1', [message])
  end

  def test_a_session_that_takes_the_pane_while_the_screen_is_read_gets_no_bell
    herdr = herdr_with('idle')
    result = ring_while_the_screen_is_read(herdr) do
      herdr.put(HERDR_SOCKET, 'w1:p2', pane_agent('idle', session: 'replacement'))
    end

    assert_equal ['absent', 'pane w1:p2 runs conversation replacement, not conversation-1'],
                 [result.status, result.detail]
    assert_empty herdr.prompts
  end

  def test_a_process_that_takes_the_pane_while_the_screen_is_read_gets_no_bell
    {
      'pane w1:p2 runs process 501, not 500' => ->(herdr) { herdr.foregrounds[[HERDR_SOCKET, 'w1:p2']] = 501 },
      'process 500 in pane w1:p2 is not the one that joined' => ->(_herdr) { processes.starts[500] = 'started again' }
    }.each do |detail, swap|
      herdr = herdr_with('idle', session: nil)
      occupant = pane_occupant(session_id: nil, **joined_process(herdr))
      result = ring_while_the_screen_is_read(herdr, occupant:) { swap.call(herdr) }

      assert_equal ['absent', detail], [result.status, result.detail]
      assert_empty herdr.prompts
    end
  end

  def test_a_herdr_that_stops_answering_while_the_screen_is_read_defers_the_bell
    herdr = herdr_with('idle')
    result = ring_while_the_screen_is_read(herdr) { herdr.unanswered << [HERDR_SOCKET, 'w1:p2'] }

    assert_equal ['deferred', 'herdr did not answer for pane w1:p2'], [result.status, result.detail]
    assert_empty herdr.prompts
  end

  def test_an_agent_that_turns_blocked_while_the_screen_is_read_defers_the_bell
    herdr = herdr_with('idle')
    result = ring_while_the_screen_is_read(herdr) { herdr.put(HERDR_SOCKET, 'w1:p2', pane_agent('blocked')) }

    assert_equal ['deferred', 'the agent is blocked'], [result.status, result.detail]
    assert_empty herdr.prompts
  end
end
