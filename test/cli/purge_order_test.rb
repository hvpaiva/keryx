# frozen_string_literal: true

require 'test_helper'

# What the hold and the order of keryx purge protect, and what its lines say of a folder a purge cut short. The first
# two tests follow rev-60's probes of #49: one fails when the checks leave the hold, the other when the mark follows
# the removal.
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

  def stamp = clock.now.utc.strftime('%Y-%m-%d %H:%M:%S UTC')

  # The mark a purge writes before it removes anything, with nothing removed yet.
  def cut_short
    mark = store.retired('rev-1.dev').with(purged_at: clock.now, purged_by: 'person.local@athena')
    File.write(tmp('state', 'addresses', 'rev-1.dev', 'retired.json'), JSON.generate(mark.record))
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

  def test_history_counts_the_kept_answer_apart_from_what_a_purge_cut_short_left
    cut_short

    assert_includes keryx('history', 'rev-1.dev').out,
                    "rev-1.dev@athena was purged at #{stamp} by person.local@athena; history lists 1 answer(s) to " \
                    'requests it sent, which purge keeps, and 1 message(s) that a purge cut short left or that ' \
                    "arrived after it, which 'keryx purge rev-1.dev' removes.\n"
  end

  def test_join_revive_counts_the_kept_answer_apart_from_what_a_purge_cut_short_left
    cut_short
    alive << 333

    assert_includes keryx('join', 'rev-1.dev', '--revive', env: claude(333)).out,
                    "Its mail was purged at #{stamp} by person.local@athena, and its mailbox holds 1 answer(s) to " \
                    'requests it sent, which purge keeps, and 1 message(s) that a purge cut short left or that ' \
                    "arrived after it.\n"
  end

  def test_join_revive_after_a_whole_purge_says_the_mailbox_holds_only_the_kept_answer
    keryx('purge', 'rev-1.dev', env: @orq)
    alive << 333

    assert_includes keryx('join', 'rev-1.dev', '--revive', env: claude(333)).out,
                    "Its mail was purged at #{stamp} by orq.dev@athena, and its mailbox holds only 1 answer(s) to " \
                    "requests it sent, which purge keeps.\n"
  end
end
