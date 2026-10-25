# frozen_string_literal: true

require 'test_helper'

class CourierCommandTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def damage(name, id)
    store.create_address(name)
    File.write(tmp('state', 'addresses', name, 'mail', "#{id}.json"), 'not json')
  end

  # Runs the courier until it has slept after the given number of rounds, and gives what it printed after each one.
  def rounds(count, env: {}, &between)
    output = StringIO.new
    terminal = Keryx::CLI::Terminal.new(out: output, err: output, env: base_env.merge(env))
    printed = []
    sleeper = lambda do |_seconds|
      printed << output.string.dup
      between&.call(printed.size)
      raise Interrupt if printed.size == count
    end
    factory = lambda do |_globals|
      Keryx::App.new(env: terminal.env, herdr:, remote:, clock:, claude_socket: sockets, codex:, sleeper:, processes:)
    end
    Keryx.run(%w[courier], terminal:, app_factory: factory)
    printed
  end

  def test_a_store_problem_is_printed_after_the_round_that_first_saw_it_and_never_again
    first = Keryx::Ulid.generate(NOW)
    later = Keryx::Ulid.generate(NOW + 1)
    damage('rev-1.dev', first)
    printed = rounds(3) { damage('rev-1.dev', later) if it == 1 }
    counts = printed.map { |out| [first, later].map { out.scan("#{it}.json").size } }

    assert_equal [[1, 0], [1, 1], [1, 1]], counts
  end

  def test_a_config_warning_is_printed_once_before_the_first_round
    write_config("hots = zeus\nhost = zeus\n")
    printed = rounds(2, env: { 'KERYX_HOST' => '' })

    assert_equal 1, printed.last.scan('unknown key "hots"').size
  end

  def test_an_agent_list_of_the_wrong_shape_defers_the_bell_and_the_round_goes_on
    store.create_address('docs.dev')
    store.bind('docs.dev', build_occupant(harness: 'cursor', session_id: 'conversation-1', herdr_socket: '/h.sock',
                                          herdr_pane: 'w1:p1'))
    rounds = ['[]', 'true', '7', '{"result":[]}', '{"result":{"agents":[true]}}'].map do |answer|
      request = build_message(to: 'docs.dev@athena', kind: 'request', body: 'Review PR #448')
      store.deliver('docs.dev', request)
      @herdr = Keryx::Herdr.new(runner: FakeRunner.new(%w[herdr agent list] => { out: answer }))
      [keryx('courier', '--once').status, store.receipt('docs.dev', request.id, 'bell')&.fetch('status')]
    end

    assert_equal [[0, Keryx::Bell::DEFERRED]] * 5, rounds
  end

  def test_the_problems_taken_are_not_kept
    app = Keryx::App.new(env: base_env, herdr:, clock:, processes:)
    damage('rev-1.dev', Keryx::Ulid.generate(NOW))
    3.times { app.store.all_messages }

    assert_equal 1, app.take_problems.size
    app.store.all_messages

    assert_empty app.take_problems
    assert_empty app.store.problems
  end
end
