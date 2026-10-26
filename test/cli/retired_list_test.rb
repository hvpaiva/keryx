# frozen_string_literal: true

require 'test_helper'

# keryx history with no ADDRESS lists the retired addresses, for whoever chooses what keryx purge removes.
class RetiredListTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def setup
    super
    @orq = join_claude('orq.dev', 111)
    join_claude('rev-1.dev', 222)
    join_claude('rev-2.dev', 333)
  end

  def retire(name, pid)
    alive.delete(pid)
    result = keryx('retire', name)
    raise "retire failed: #{result.err}" unless result.status.zero?
  end

  def ago(seconds) = "#{Keryx::Duration.short(seconds)} ago"

  def rows(out) = out.lines(chomp: true).map { it.strip.split(/ {3,}/) }

  # rev-1.dev retired with a message written an hour and a minute ago, rev-2.dev retired and purged, orq.dev live,
  # and a folder from before team names.
  def retired_and_purged
    keryx('send', 'rev-1.dev', 'heads-up', env: @orq)
    clock.advance(60)
    retire('rev-1.dev', 222)
    retire('rev-2.dev', 333)
    keryx('purge', 'rev-2.dev', env: @orq)
    FileUtils.mkdir_p(tmp('state', 'addresses', 'hvpaiva'))
    File.write(tmp('state', 'addresses', 'hvpaiva', 'address.json'), '{"name":"hvpaiva"}')
    clock.advance(3600)
  end

  def test_history_with_no_address_lists_the_retired_addresses_and_when_each_last_had_mail
    retired_and_purged

    assert_equal [['ADDRESS', 'RETIRED', 'BY', 'MAIL', 'LAST MAIL', 'PURGED'],
                  ['rev-1.dev@athena', ago(3600), 'person.local@athena', '1', ago(3660), '-'],
                  ['rev-2.dev@athena', ago(3600), 'person.local@athena', '0', '-', ago(3600)]],
                 rows(keryx('history').out)
  end

  def test_history_with_no_address_prints_the_listing_as_json
    retired_and_purged
    listed = JSON.parse(keryx('history', '-o', 'json').out)

    assert_equal([Keryx::CLI::Command::SCHEMA] * 2, listed.map { it['schema'] })
    assert_equal([{ 'address' => 'rev-1.dev@athena', 'retired_at' => (NOW + 60).utc.iso8601,
                    'retired_by' => 'person.local@athena', 'mail' => 1, 'last_mail_at' => NOW.utc.iso8601,
                    'purged_at' => nil, 'purged_by' => nil },
                  { 'address' => 'rev-2.dev@athena', 'retired_at' => (NOW + 60).utc.iso8601,
                    'retired_by' => 'person.local@athena', 'mail' => 0, 'last_mail_at' => nil,
                    'purged_at' => (NOW + 60).utc.iso8601, 'purged_by' => 'orq.dev@athena' }],
                 listed.map { it.except('schema') })
  end

  def test_history_with_no_address_says_when_nothing_is_retired_and_refuses_what_reads_one_address
    empty = keryx('history')

    assert_equal [0, "No retired addresses on athena.\n"], [empty.status, empty.out]
    [%w[--sent], %w[--id 01M5], %w[--thread 01M5], %w[--to orq]].each do |option|
      result = keryx('history', *option)

      assert_equal [2, "error: --sent, --id, --thread and --to read one address; give ADDRESS\n"],
                   [result.status, result.err.lines.first], option
    end
  end

  def test_a_damaged_retirement_record_is_a_problem_and_its_address_is_left_out
    retired_and_purged
    File.write(tmp('state', 'addresses', 'rev-1.dev', 'retired.json'), '{"retired_at":"never"}')
    result = keryx('history')

    assert_equal %w[rev-2.dev@athena], rows(result.out).drop(1).map(&:first)
    assert_match(/rev-1\.dev.retired\.json is damaged/, result.err)
  end
end
