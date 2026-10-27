# frozen_string_literal: true

require 'test_helper'

class DeliveryTest < Minitest::Test
  include Factory

  def test_a_message_whose_answer_was_not_recorded_waits_without_blaming_the_host
    reason = format(Keryx::Forwarder::UNRECORDED, host: 'zeus')

    assert_equal "The message waits in the outbox, since #{reason}.", Keryx::Commands::Delivery.note(waiting(reason))
  end

  def test_a_message_the_host_did_not_answer_waits_for_the_host
    assert_equal "zeus did not answer (no route to zeus); the message waits in the outbox and 'keryx courier' " \
                 'forwards it once zeus is back.', Keryx::Commands::Delivery.note(waiting('no route to zeus'))
  end

  private

  def waiting(detail)
    forward = Keryx::Forwarder::Result.new(status: Keryx::Forwarder::QUEUED, detail:, bell: nil)
    Keryx::Postman::Posted.new(message: build_message(to: 'port.dev@zeus'), bell: nil, forward:)
  end
end
