# frozen_string_literal: true

require 'test_helper'
require 'digest'

class ActivityTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def setup
    super
    @orq = join_claude('orq', 111, role: 'orchestrator')
  end

  def written(age, *parts)
    path = tmp('home', *parts)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, '')
    File.utime(clock.now - age, clock.now - age, path)
  end

  def transcript(pid, age) = written(age, '.claude', 'projects', '-work', "session-#{pid}.jsonl")

  def column(output, title)
    rows = output.split("\n\n").first.lines.reject { it.start_with?('ADDRESSES') }.map { it.strip.split(/ {3,}/) }
    index = rows.first.index(title)
    rows.drop(1).to_h { [it.first, it[index]] }
  end

  def last_activity(command)
    data = JSON.parse(keryx(command, '--all', '-o', 'json').out)
    data['addresses'].to_h { it.values_at('address', 'last_activity') }
  end

  def test_who_and_status_show_when_each_session_last_wrote_its_record
    transcript(111, 300)
    join_claude('rev-1', 222)
    join_claude('ended', 333)
    transcript(333, 60)
    alive.delete(333)
    expected = { 'orq@athena' => '5m ago', 'rev-1@athena' => 'unknown', 'ended@athena' => '-' }

    assert_equal expected, column(keryx('who', '--all').out, 'ACTIVE')
    assert_equal expected, column(keryx('status', '--all').out, 'ACTIVE')
  end

  def test_active_follows_session_in_both_tables
    assert_equal %w[ADDRESS ROLE HARNESS SESSION ACTIVE CONTEXT UNREAD], keryx('who').out.lines.first.split
    assert_equal %w[ADDRESS ROLE SESSION ACTIVE CONTEXT UNREAD WAITING], keryx('status').out.lines[1].split
  end

  def test_json_gives_the_time_itself_and_null_when_there_is_none
    transcript(111, 300)
    join_claude('rev-1', 222)
    join_claude('ended', 333)
    transcript(333, 60)
    alive.delete(333)
    expected = { 'orq@athena' => (clock.now - 300).utc.iso8601, 'rev-1@athena' => nil, 'ended@athena' => nil }

    assert_equal expected, last_activity('who')
    assert_equal expected, last_activity('status')
  end

  def test_a_time_ahead_of_the_clock_reads_as_now
    transcript(111, -90)

    assert_equal '0s ago', column(keryx('who').out, 'ACTIVE')['orq@athena']
  end

  def test_cursor_reads_the_store_of_the_conversation_it_joined_with
    agent = Keryx::Herdr::Agent.new(pane: 'w1:p3', kind: 'cursor', status: 'idle', session: 'conversation-1')
    herdr.put('/h.sock', 'w1:p3', agent)
    keryx('join', 'docs', env: { 'CURSOR_CONVERSATION_ID' => 'conversation-1', 'HERDR_SOCKET_PATH' => '/h.sock',
                                 'HERDR_PANE_ID' => 'w1:p3' })
    written(7200, '.cursor', 'chats', Digest::MD5.hexdigest('/work'), 'conversation-1', 'store.db')

    assert_equal '2h ago', column(keryx('who').out, 'ACTIVE')['docs@athena']
  end
end
