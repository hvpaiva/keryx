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
    damage('rev-1', first)
    printed = rounds(3) { damage('rev-1', later) if it == 1 }
    counts = printed.map { |out| [first, later].map { out.scan("#{it}.json").size } }

    assert_equal [[1, 0], [1, 1], [1, 1]], counts
  end

  def test_a_config_warning_is_printed_once_before_the_first_round
    write_config("hots = zeus\nhost = zeus\n")
    printed = rounds(2, env: { 'KERYX_HOST' => '' })

    assert_equal 1, printed.last.scan('unknown key "hots"').size
  end

  def test_the_problems_taken_are_not_kept
    app = Keryx::App.new(env: base_env, herdr:, clock:, processes:)
    damage('rev-1', Keryx::Ulid.generate(NOW))
    3.times { app.store.all_messages }

    assert_equal 1, app.take_problems.size
    app.store.all_messages

    assert_empty app.take_problems
    assert_empty app.store.problems
  end
end
