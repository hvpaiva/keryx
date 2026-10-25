# frozen_string_literal: true

require 'test_helper'

class HandoverNoticesTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  FIXTURES = File.expand_path('../fixtures/context', __dir__)

  def claude_transcript(pid)
    path = tmp('home', '.claude', 'projects', '-work', "session-#{pid}.jsonl")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, File.read(File.join(FIXTURES, 'claude-transcript.jsonl')).gsub('"session-1"', %("session-#{pid}")))
  end

  # The session in pid OLD joins NAME and a session in pid NEW takes it with join --force. Returns the session the
  # displaced one keeps.
  def take_over(name, old, new, *argv)
    alive << old << new
    keryx('join', name, *argv, env: claude(old))
    session = store.occupant(name).session
    result = keryx('join', name, '--force', env: claude(new))
    raise "join failed: #{result.err}" unless result.status.zero?

    session
  end

  # The addresses keryx's own notices in the inbox of ENV went to.
  def notices(env)
    JSON.parse(keryx('inbox', '-o', 'json', env:).out).filter_map { it['to'] if it['from'] == 'keryx.system@athena' }
  end

  def test_the_courier_tells_a_displaced_session_with_a_ceiling_at_its_session_address
    orq = join_claude('orq.dev', 111)
    claude_transcript(222)
    session = take_over('rev-1.dev', 222, 333, '--ceiling', '125k')
    store.bind("rev-1.dev/#{session}", store.occupant("rev-1.dev/#{session}").with(director: 'orq.dev'))
    old = "rev-1.dev@athena/#{session}"
    rung = sockets.posts.size
    near = "#{old} is at 121k 97% of 125k, near its context ceiling"

    assert_equal "told #{old} that #{near}\ntold orq.dev@athena that #{near}\n", keryx('courier', '--once').out
    assert_equal %w[/tmp/cc-222.sock /tmp/cc-111.sock], sockets.posts.drop(rung).map(&:first)
    assert_equal([[old], [], ['orq.dev@athena']], [claude(222), claude(333), orq].map { notices(it) })
    assert_empty keryx('courier', '--once').out
  end
end
