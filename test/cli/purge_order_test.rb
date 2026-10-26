# frozen_string_literal: true

require 'test_helper'

# What the hold and the order of keryx purge protect. The tests follow rev-60's probes of #49: one fails when the
# checks leave the hold, the other when the mark follows the removal.
class PurgeOrderTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  # rev-1.dev has the answer to a request it sent and a message from orq.dev, and is retired.
  def setup
    super
    @orq = join_claude('orq.dev', 111)
    rev = join_claude('rev-1.dev', 222)
    question = keryx('ask', 'orq.dev', 'Which branch?', env: rev).out[/\AAsked \S+ \((\w{26})\)/, 1]
    clock.advance(1)
    keryx('reply', question, 'main', env: @orq)
    keryx('send', 'rev-1.dev', 'heads-up', env: @orq)
    alive.delete(222)
    keryx('retire', 'rev-1.dev')
  end

  # DURING runs once in the store, as purge asks for the occupants lock and before it holds it, while the block runs
  # purge.
  def while_purge_waits(during)
    original = Keryx::Store.instance_method(:with_occupants_lock)
    fired = false
    Keryx::Store.define_method(:with_occupants_lock) do |*args, **kw, &held|
      if !fired && caller_locations.any? { it.path.end_with?('commands/purge.rb') }
        fired = true
        instance_exec(&during)
      end
      original.bind_call(self, *args, **kw, &held)
    end
    result = yield

    assert fired
    result
  ensure
    Keryx::Store.define_method(:with_occupants_lock, original)
  end

  def test_a_request_written_while_purge_waits_for_the_lock_makes_purge_refuse
    request = build_message(kind: 'request', from: 'orq.dev@athena', to: 'rev-1.dev@athena', created_at: clock.now)
    result = while_purge_waits(-> { deliver('rev-1.dev', request) }) { keryx('purge', 'rev-1.dev', env: @orq) }

    assert_equal 1, result.status, result.out
    assert_includes result.err, "#{request.id} from orq.dev@athena waits for its answer"
    refute_predicate store.retired('rev-1.dev'), :purged?
  end

  def test_a_purge_killed_during_the_removal_leaves_the_mark_and_a_second_run_finishes_it
    calls = 0
    original = FileUtils.method(:rm_r)
    # A throw leaves purge as a kill would, past every rescue, at the second removal.
    FileUtils.define_singleton_method(:rm_r) do |*args, **kw|
      throw :killed if (calls += 1) > 1

      original.call(*args, **kw)
    end
    catch(:killed) { keryx('purge', 'rev-1.dev', env: @orq) }
    FileUtils.define_singleton_method(:rm_r, original)

    assert_operator calls, :>, 1

    assert_predicate store.retired('rev-1.dev'), :purged?
    assert_match(/\AFinished purging rev-1.dev@athena/, keryx('purge', 'rev-1.dev', env: @orq).out)
  ensure
    FileUtils.define_singleton_method(:rm_r, original)
  end
end
