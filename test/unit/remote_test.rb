# frozen_string_literal: true

require 'test_helper'

class RemoteTest < Minitest::Test
  include Factory

  def queued = @queued ||= build_message(to: 'port@zeus')

  def test_it_pipes_the_messages_to_keryx_over_ssh_and_reads_the_receipts
    receipt = { 'id' => queued.id, 'status' => 'delivered' }
    runner = FakeRunner.new({ ['ssh'] => { out: "#{JSON.generate(receipt)}\nnoise\n" } })
    answer = Keryx::Remote.new(runner:).deliver('zeus', [queued])

    assert_equal(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', 'zeus', 'keryx __receive'],
                 runner.calls.first[0])
    assert_equal "#{queued.to_json}\n", runner.inputs.first
    assert_equal [{ queued.id => receipt }, nil], [answer.receipts, answer.error]
  end

  def test_a_failed_connection_reports_the_last_line_ssh_printed
    err = "Warning: something\nssh: connect to host zeus port 22: No route to host\n"
    answer = Keryx::Remote.new(runner: FakeRunner.new({ ['ssh'] => { success: false, err: } }))
                          .deliver('zeus', [queued])

    assert_equal [{}, 'ssh: connect to host zeus port 22: No route to host'], [answer.receipts, answer.error]
  end

  def test_the_environment_chooses_the_ssh_command_and_the_remote_keryx
    runner = FakeRunner.new({ ['ssh'] => { out: '' } })
    env = { 'KERYX_SSH' => 'ssh -F /etc/keryx/ssh_config', 'KERYX_REMOTE_COMMAND' => '~/.local/bin/keryx' }
    Keryx::Remote.from_env(env, runner:).deliver('zeus', [queued])

    assert_equal ['ssh', '-F', '/etc/keryx/ssh_config'], runner.calls.first[0].first(3)
    assert_equal '~/.local/bin/keryx __receive', runner.calls.first[0].last
  end
end
