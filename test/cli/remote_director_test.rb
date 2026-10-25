# frozen_string_literal: true

require 'test_helper'

# The ceiling notices of a session whose director is the sender of its oldest request, on another machine, at a
# session address there.
class RemoteDirectorTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  FIXTURES = File.expand_path('../fixtures/context', __dir__)

  # orq.dev on zeus is taken over with join --force, and its displaced session asks impl.dev here, which runs with a
  # ceiling of 125k and 121k of context.
  def setup
    super
    alive.push(111, 222, 333)
    @old = machine('zeus').merge(claude(111))
    @holder = machine('zeus').merge(claude(222))
    keryx('join', 'orq.dev', env: @old)
    @session = Keryx::Store.new(tmp('zeus')).occupant('orq.dev').session
    keryx('join', 'orq.dev', '--force', env: @holder)
    keryx('join', 'impl.dev', '--ceiling', '125k', env: claude(333))
    claude_transcript(333)
    keryx('ask', 'impl.dev@athena', 'Review the change', env: @old)
  end

  def claude_transcript(pid)
    path = tmp('home', '.claude', 'projects', '-work', "session-#{pid}.jsonl")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, File.read(File.join(FIXTURES, 'claude-transcript.jsonl')).gsub('"session-1"', %("session-#{pid}")))
  end

  # What each courier round printed, a minute apart.
  def rounds(count)
    Array.new(count) { keryx('courier', '--once').then { |round| clock.advance(60).then { round.out + round.err } } }
  end

  # The addresses keryx's notices in the inbox of ENV went to.
  def notices(env)
    JSON.parse(keryx('inbox', '-o', 'json', env:).out).filter_map { it['to'] if it['from'] == 'keryx.system@athena' }
  end

  def test_a_session_that_still_runs_there_is_told_at_its_session_address
    rounds(1)

    assert_equal ["orq.dev@zeus/#{@session}"], notices(@old)
    assert_empty notices(@holder)
  end

  def test_the_holder_there_is_told_once_that_session_left_and_no_round_fails
    keryx('leave', env: @old)
    printed = rounds(2)

    printed.each { refute_match(/could not tell/, it) }

    assert_equal ["orq.dev@zeus/#{@session}"], notices(@holder)
  end

  def test_a_notice_that_waited_in_the_outbox_reaches_the_holder_there
    keryx('leave', env: @old)
    remote.down << 'zeus'
    rounds(1)
    remote.down.delete('zeus')
    rounds(1)

    assert_equal ["orq.dev@zeus/#{@session}"], notices(@holder)
    assert_empty JSON.parse(keryx('status', '-o', 'json').out)['not_forwarded']
  end
end
