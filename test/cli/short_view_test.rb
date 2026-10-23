# frozen_string_literal: true

require 'test_helper'

class ShortViewTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def setup
    super
    @orq = join_claude('orq', 111)
    join_claude('rev-1', 222)
    alive.delete(222)
    keryx('whoami')
  end

  def addresses(output) = output.lines.drop(1).take_while { it.start_with?(/[a-z]/) }.map { it.split.first }

  def who_json(*argv) = JSON.parse(keryx('who', *argv, '-o', 'json').out)

  def status_json(*argv) = JSON.parse(keryx('status', *argv, '-o', 'json').out)

  def asked(recipient, env:) = keryx('ask', recipient, 'Review it', env:).out[/\AAsked \S+ \((\w{26})\)/, 1]

  def join_and_end(name, pid)
    env = join_claude(name, pid)
    yield env if block_given?
    alive.delete(pid)
  end

  def test_who_hides_the_addresses_nobody_holds_and_nobody_writes_to
    output = keryx('who').out

    assert_equal %w[orq@athena], addresses(output)
    assert_equal "2 addresses with no session and no mail are hidden; 'keryx who --all' lists them.\n",
                 output.lines.last
    assert_equal %w[orq@athena person@athena rev-1@athena], addresses(keryx('who', '--all').out)
    refute_match(/hidden/, keryx('who', '-a').out)
  end

  def test_unread_mail_and_open_requests_either_way_keep_an_address_in_view
    keryx('send', 'rev-1', 'heads-up', env: @orq)
    join_and_end('impl', 333) { asked('orq', env: it) }
    join_and_end('docs', 444) { |env| keryx('read', asked('docs', env: @orq), env:) }
    join_and_end('qa', 555)

    assert_equal(%w[docs@athena impl@athena orq@athena rev-1@athena], who_json['addresses'].map { it['address'] })
  end

  def test_an_address_whose_session_keryx_cannot_tell_stays_in_view
    File.write(tmp('state', 'addresses', 'rev-1', 'occupant.json'), '{}')

    assert_equal(%w[orq@athena rev-1@athena], who_json['addresses'].map { it['address'] })
  end

  def test_the_note_counts_one_address_or_every_one
    alive << 333
    keryx('join', 'rev-1', env: claude(333))

    assert_equal "1 address with no session and no mail is hidden; 'keryx who --all' lists it.\n",
                 keryx('who').out.lines.last
    [111, 333].each { alive.delete(it) }

    assert_equal "3 addresses with no session and no mail are hidden; 'keryx who --all' lists them.\n",
                 keryx('who').out
  end

  def test_json_says_which_view_it_is
    assert_equal({ 'view' => 'short', 'hidden' => 2 }, who_json.slice('view', 'hidden'))
    assert_equal({ 'view' => 'all', 'hidden' => 0 }, who_json('--all').slice('view', 'hidden'))
    assert_equal 3, who_json('--all')['addresses'].size
    assert_equal({ 'view' => 'short', 'hidden' => 2 }, status_json.slice('view', 'hidden'))
    assert_equal({ 'view' => 'all', 'hidden' => 0 }, status_json('--all').slice('view', 'hidden'))
    assert_equal(%w[orq@athena], status_json['addresses'].map { it['address'] })
  end

  def test_status_hides_them_under_addresses_and_says_how_many
    shown = keryx('status').out.split("\n\n").first.lines
    alive.delete(111)
    none = keryx('status').out.split("\n\n").first.lines

    assert_equal ['orq@athena', 4], [shown[2].split.first, shown.size]
    assert_equal "2 addresses with no session and no mail are hidden; 'keryx status --all' lists them.", shown.last
    assert_equal ["ADDRESSES\n", "none\n",
                  "3 addresses with no session and no mail are hidden; 'keryx status --all' lists them."], none
    assert_equal %w[orq@athena person@athena rev-1@athena], addresses(keryx('status', '--all').out.lines.drop(1).join)
  end
end
