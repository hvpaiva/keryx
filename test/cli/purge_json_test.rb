# frozen_string_literal: true

require 'test_helper'

class PurgeJSONTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def setup
    super
    @orq = join_claude('orq.dev', 111)
    @rev = join_claude('rev-1.dev', 222)
  end

  def json(*argv) = keryx('purge', *argv, '-o', 'json', env: @orq)

  def asked(recipient, text, env:) = keryx('ask', recipient, text, env:).out[/\AAsked \S+ \((\w{26})\)/, 1]

  def retired
    alive.delete(222)
    result = keryx('retire', 'rev-1.dev')
    raise "retire failed: #{result.err}" unless result.status.zero?
  end

  def box(*parts) = tmp('state', 'addresses', 'rev-1.dev', *parts)

  def at(time) = time.utc.iso8601

  def receipts = Dir.children(box('receipts')).size

  def state
    root = tmp('state')
    Dir.glob('**/*', File::FNM_DOTMATCH, base: root).sort.map do |path|
      full = File.join(root, path)
      [path, File.lstat(full).file? ? File.binread(full) : File.lstat(full).ftype]
    end
  end

  def removed(messages, read_marks, receipts)
    { 'messages' => messages, 'read_marks' => read_marks, 'receipts' => receipts, 'being_written' => 0 }
  end

  def done(outcome, **fields)
    { 'schema' => 1, 'address' => 'rev-1.dev@athena', 'outcome' => outcome, 'retired_by' => 'person.local@athena',
      **fields }
  end

  # A refusal prints its document on stdout, and its error goes to stderr as without -o json, with the same exit.
  def assert_refused(argv, address, reason, fields = {})
    before = state
    text = keryx('purge', *argv, env: @orq)
    result = json(*argv)

    assert_equal 1, result.status
    assert_equal({ 'schema' => 1, 'address' => address, 'outcome' => 'refused', 'reason' => reason,
                   'error' => text.err.lines.first.delete_prefix('error: ').chomp, **fields }, JSON.parse(result.out))
    assert_equal [1, text.err], [text.status, result.err]
    assert_equal before, state
  end

  # rev-1.dev has the answer to a request it sent, which purge keeps, and a message from orq.dev, both read.
  def exchange
    question = asked('orq.dev', 'Which branch?', env: @rev)
    clock.advance(1)
    keryx('reply', question, 'main', env: @orq)
    clock.advance(1)
    keryx('send', 'rev-1.dev', 'heads-up', env: @orq)
    2.times { keryx('read', env: @rev) }
  end

  def test_purge_prints_what_it_removed_and_the_mark_retired_json_records
    exchange
    retired_at = at(clock.now)
    retired
    count = receipts
    clock.advance(60)
    result = json('rev-1.dev')
    record = JSON.parse(File.read(box('retired.json')))

    assert_equal [0, ''], [result.status, result.err]
    assert_equal done('purged', 'retired_at' => retired_at, 'purged_at' => at(clock.now),
                                'purged_by' => 'orq.dev@athena', 'removed' => removed(1, 1, count),
                                'answers_kept' => 1), JSON.parse(result.out)
    assert_equal [record['purged_at'], record['purged_by']], JSON.parse(result.out).values_at('purged_at', 'purged_by')
    assert_equal 1, Dir.children(box('mail')).size
  end

  def test_a_dry_run_prints_what_purge_would_remove_with_no_mark_and_changes_nothing
    keryx('send', 'rev-1.dev', 'heads-up', env: @orq)
    retired_at = at(clock.now)
    retired
    before = state
    result = json('rev-1.dev', '--dry-run')

    assert_equal [0, ''], [result.status, result.err]
    assert_equal done('dry_run', 'retired_at' => retired_at, 'purged_at' => nil, 'purged_by' => nil,
                                 'removed' => removed(1, 0, receipts), 'answers_kept' => 0), JSON.parse(result.out)
    assert_equal before, state
  end

  def test_a_purge_that_finishes_one_cut_short_prints_the_first_mark
    keryx('send', 'rev-1.dev', 'heads-up', env: @orq)
    retired_at = at(clock.now)
    retired
    mark = store.retired('rev-1.dev').with(purged_at: clock.now, purged_by: 'orq.dev@athena').record
    File.write(box('retired.json'), JSON.generate(mark))
    count = receipts
    clock.advance(60)
    result = json('rev-1.dev')

    assert_equal [0, ''], [result.status, result.err]
    assert_equal done('finished', 'retired_at' => retired_at, 'purged_at' => retired_at,
                                  'purged_by' => 'orq.dev@athena', 'removed' => removed(1, 0, count),
                                  'answers_kept' => 0), JSON.parse(result.out)
    assert_equal mark, JSON.parse(File.read(box('retired.json')))
  end

  def test_purge_refuses_a_session_address
    assert_refused(['rev-1.dev@athena/abcdef'], 'rev-1.dev@athena/abcdef', 'session')
  end

  def test_purge_refuses_an_address_on_another_machine_and_names_the_machine
    assert_refused(['rev-1.dev@zeus'], 'rev-1.dev@zeus', 'remote', { 'host' => 'zeus' })
  end

  def test_purge_refuses_an_address_from_before_team_names
    assert_refused(['hvpaiva@athena'], 'hvpaiva@athena', 'no_team')
  end

  def test_purge_refuses_an_address_in_a_reserved_scope
    assert_refused(['person.local'], 'person.local@athena', 'reserved')
    assert_refused(['keryx.system'], 'keryx.system@athena', 'reserved')
  end

  def test_purge_refuses_an_address_with_no_folder_here
    assert_refused(['nobody.dev'], 'nobody.dev@athena', 'no_address')
  end

  def test_purge_refuses_an_address_that_is_not_retired
    assert_refused(['rev-1.dev'], 'rev-1.dev@athena', 'not_retired')
  end

  def test_a_dry_run_that_purge_refuses_prints_the_refusal
    assert_refused(['rev-1.dev', '--dry-run'], 'rev-1.dev@athena', 'not_retired')
  end

  def test_purge_refuses_an_address_purged_already_and_gives_the_mark
    retired
    clock.advance(60)
    purged_at = at(clock.now)
    keryx('purge', 'rev-1.dev', env: @orq)

    mark = { 'purged_at' => purged_at, 'purged_by' => 'orq.dev@athena' }

    assert_refused(['rev-1.dev'], 'rev-1.dev@athena', 'purged_already', mark)
  end

  def test_purge_refuses_while_requests_wait_either_way_and_names_each
    received = asked('rev-1.dev', 'Review PR #448', env: @orq)
    sent = asked('orq.dev', 'Which branch?', env: @rev)
    alive.delete(222)
    store.retire('rev-1.dev', by: 'orq.dev@athena', now: clock.now)

    waiting = { 'received' => [{ 'id' => received, 'from' => 'orq.dev@athena' }],
                'sent' => [{ 'id' => sent, 'to' => 'orq.dev@athena' }] }

    assert_refused(['rev-1.dev'], 'rev-1.dev@athena', 'waiting', waiting)
  end

  def test_purge_refuses_while_the_outbox_holds_what_the_address_sent_and_names_each_by_host
    remote.down << 'zeus'
    keryx('send', 'port.dev@zeus', 'hello', env: @rev)
    retired
    queued = store.outbox.queued('zeus').map(&:id)

    assert_equal 1, queued.size
    assert_refused(['rev-1.dev'], 'rev-1.dev@athena', 'queued', { 'queued' => [{ 'host' => 'zeus', 'ids' => queued }] })
  end

  def test_an_error_that_is_not_a_refusal_of_purge_leaves_stdout_empty
    retired
    File.write(box('retired.json'), '[]')
    damaged = json('rev-1.dev')

    assert_equal [1, '', "error: #{box('retired.json')} is damaged\n"], [damaged.status, damaged.out, damaged.err]
    [[1, 'Rev!'], [2, 'rev-1.dev', '--bogus']].each do |status, *argv|
      result = json(*argv)

      assert_equal [status, ''], [result.status, result.out], argv
    end
  end
end
