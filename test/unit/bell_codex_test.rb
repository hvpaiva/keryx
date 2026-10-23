# frozen_string_literal: true

require 'test_helper'

class BellCodexTest < Minitest::Test
  include TempDir
  include Factory
  include BellHelpers

  def codex_occupant(**overrides) = pane_occupant(harness: 'codex', session_id: 'thread-1', **overrides)

  def codex_pane(status, session: nil) = herdr_with(status, kind: 'codex', session:)

  def joined_process(herdr, pid: 500)
    processes.alive << pid
    herdr.foregrounds[[HERDR_SOCKET, 'w1:p2']] = pid
    { pid:, started: "started #{pid}" }
  end

  def test_a_codex_thread_herdr_shows_open_in_its_pane_is_rung_through_its_queue
    message = deliver
    store.bind('rev-1', codex_occupant)
    herdr = codex_pane('working', session: 'thread-1')
    result = bell(herdr:).ring('rev-1', [message])

    assert_equal %w[rung codex], [result.status, result.channel]
    assert_equal 'thread-1', queue.queued.first.first
    assert_match(/\A\[keryx\] New request for rev-1@athena/, queue.queued.first.last)
    assert_empty herdr.prompts
  end

  def test_a_codex_thread_closed_in_its_pane_is_absent_and_never_queued
    message = deliver
    store.bind('rev-1', codex_occupant)
    result = bell.ring('rev-1', [message])

    assert_equal ['absent', 'no agent runs in pane w1:p2'], [result.status, result.detail]
    assert_empty queue.queued
  end

  def test_a_codex_thread_without_a_pane_is_absent_and_never_queued
    message = deliver
    store.bind('rev-1', build_occupant(harness: 'codex', session_id: 'thread-1'))
    result = bell.ring('rev-1', [message])

    assert_equal ['absent', 'thread thread-1 has no herdr pane'], [result.status, result.detail]
    assert_empty queue.queued
  end

  def test_a_codex_pane_without_a_session_id_is_typed_when_its_process_is_the_one_that_joined
    message = deliver
    herdr = codex_pane('idle')
    store.bind('rev-1', codex_occupant(**joined_process(herdr)))
    result = bell(herdr:).ring('rev-1', [message])

    assert_equal %w[rung herdr], [result.status, result.channel]
    assert_equal 1, herdr.prompts.size
    assert_empty queue.queued
  end

  def test_a_codex_pane_without_a_session_id_is_absent_when_nothing_shows_the_process_that_joined
    {
      format(Keryx::Lookout::NO_PROCESS, pane: 'w1:p2') => ->(_herdr) { {} },
      'pane w1:p2 runs process 501, not 500' => ->(herdr) { joined_process(herdr, pid: 501).merge(pid: 500) },
      'process 500 in pane w1:p2 is not the one that joined' => lambda do |herdr|
        joined_process(herdr).tap { processes.starts[500] = 'started again' }
      end
    }.each do |detail, process|
      message = deliver
      herdr = codex_pane('idle')
      store.bind('rev-1', codex_occupant(**process.call(herdr)))
      result = bell(herdr:).ring('rev-1', [message])

      assert_equal ['absent', detail], [result.status, result.detail]
      assert_empty herdr.prompts
      assert_empty queue.queued
    end
  end

  def test_a_herdr_that_does_not_answer_defers_the_bell
    message = deliver
    herdr = codex_pane('idle', session: 'thread-1')
    herdr.unanswered << [HERDR_SOCKET, 'w1:p2']
    store.bind('rev-1', codex_occupant)
    result = bell(herdr:).ring('rev-1', [message])

    assert_equal ['deferred', 'herdr did not answer for pane w1:p2'], [result.status, result.detail]
    assert_empty queue.queued
  end

  def test_a_codex_pane_running_another_thread_is_absent_and_neither_typed_nor_queued
    message = deliver
    store.bind('rev-1', codex_occupant)
    herdr = codex_pane('idle', session: 'thread-2')
    result = bell(herdr:).ring('rev-1', [message])

    assert_equal ['absent', 'pane w1:p2 runs thread thread-2, not thread-1'], [result.status, result.detail]
    assert_empty herdr.prompts
    assert_empty queue.queued
  end

  def test_an_open_codex_thread_whose_queue_fails_is_typed_into_its_pane
    message = deliver
    queue.gone << 'thread-1'
    store.bind('rev-1', codex_occupant)
    herdr = codex_pane('idle', session: 'thread-1')
    result = bell(herdr:).ring('rev-1', [message])

    assert_equal %w[rung herdr], [result.status, result.channel]
    assert_equal 1, herdr.prompts.size
  end

  def test_a_failed_queue_types_only_into_what_the_pane_runs_after_it
    message = deliver
    store.bind('rev-1', codex_occupant)
    herdr = codex_pane('idle', session: 'thread-1')
    queue.gone << 'thread-1'
    queue.on_queue = lambda do |_thread|
      herdr.put(HERDR_SOCKET, 'w1:p2', Keryx::Herdr::Agent.new(pane: 'w1:p2', kind: 'claude', status: 'idle'))
    end
    result = bell(herdr:).ring('rev-1', [message])

    assert_equal ['absent', 'pane w1:p2 runs claude, not codex'], [result.status, result.detail]
    assert_empty herdr.prompts
  end
end
