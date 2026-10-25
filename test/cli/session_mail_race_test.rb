# frozen_string_literal: true

require 'test_helper'

class SessionMailRaceTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include ProcessRaces

  # The sessions run as processes, which keryx sees running only if it recorded them from a process of its own.
  def setup
    super
    @old = claude(Process.pid)
    finish([start('old', 'join', 'rev.dev', env: @old, pause: 'none')])
    @session = store.occupant('rev.dev').session
    @new = claude(Process.ppid)
    finish([start('new', 'join', 'rev.dev', '--force', env: @new, pause: 'none')])
  end

  def old_address = "rev.dev@athena/#{@session}"

  def bodies = store.stored('rev.dev').map { it.message.body }

  def test_a_send_that_found_the_session_bound_writes_nothing_once_it_left
    leave = stopped(start('leave', 'leave', env: @old, pause: 'unbind'))
    send = start('send', 'send', old_address, 'Too late', env: {}, pause: 'none')

    assert_equal({ 'leave' => 0, 'send' => 1 }, finish(release_when_ended_or_waiting(leave, send)))
    assert_equal "error: mail to #{old_address} is refused: its session left; write to rev.dev@athena\n",
                 File.read(tmp('pause-send.err'))
    assert_empty bodies
  end

  def test_a_leave_waits_for_mail_its_session_is_sent_and_the_holder_takes_it
    send = stopped(start('send', 'send', old_address, 'Just in time', env: {}, pause: 'deliver'))
    leave = start('leave', 'leave', env: @old, pause: 'none')

    assert_equal({ 'send' => 0, 'leave' => 0 }, finish(release_when_ended_or_waiting(send, leave)))
    assert marked?('leave', 'waiting'), 'the leave came between the check of the session and the write'
    assert_equal ['Just in time'], bodies
    assert_equal([old_address], JSON.parse(keryx('inbox', '-o', 'json', env: @new).out).map { it['to'] })
  end
end
