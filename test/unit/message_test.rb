# frozen_string_literal: true

require 'test_helper'

class MessageTest < Minitest::Test
  CREATED = Time.utc(2026, 10, 22, 17, 0, 0)

  def build_message(**overrides)
    Keryx::Message.new(id: '01JB8Y2Q7M0000000000000000', kind: 'request', from: 'orq.dev@athena',
                       to: 'rev-1.dev@athena', thread: '01JB8Y2Q7M0000000000000000', in_reply_to: nil,
                       created_at: CREATED, due_at: CREATED + 1800, body: "Review PR #448\n\nFocus on the retry path.",
                       **overrides)
  end

  def test_json_round_trips_every_field
    original = build_message

    assert_equal original, Keryx::Message.from_json(original.to_json)
  end

  def test_json_carries_the_format_version_and_utc_times
    data = JSON.parse(build_message(created_at: Time.new(2026, 10, 22, 14, 0, 0, '-03:00')).to_json)

    assert_equal 2, data['keryx']
    assert_equal '2026-10-22T17:00:00Z', data['created_at']
  end

  def test_a_message_between_two_addresses_from_before_team_names_keeps_the_old_format
    flat = build_message(from: 'orq@athena', to: 'port@zeus')
    data = JSON.parse(flat.to_json)

    assert_equal 1, data['keryx']
    assert_equal flat, Keryx::Message.from_json(flat.to_json)
    assert_equal 2, JSON.parse(build_message(from: 'orq@athena', to: 'port.ports@zeus').to_json)['keryx']
    assert_equal 2, JSON.parse(build_message(from: 'orq.dev@athena/k3m9qz', to: 'port.ports@zeus').to_json)['keryx']
  end

  def test_the_old_format_carries_only_addresses_without_a_team
    data = JSON.parse(build_message.to_json).merge('keryx' => 1)

    error = assert_raises(Keryx::Error) { Keryx::Message.from_json(JSON.generate(data)) }
    assert_equal 'format 1 carries only addresses without a team', error.message
  end

  def test_an_unknown_format_is_not_a_keryx_message
    data = JSON.parse(build_message.to_json).merge('keryx' => 3)

    error = assert_raises(Keryx::Error) { Keryx::Message.from_json(JSON.generate(data)) }
    assert_equal 'not a keryx message', error.message
  end

  def test_from_json_rejects_what_is_not_a_message
    ['{', '[]', '{"keryx":2}', JSON.generate('keryx' => 1, 'id' => 'x')].each do |text|
      assert_raises(Keryx::Error, text) { Keryx::Message.from_json(text) }
    end
  end

  def test_from_json_rejects_an_unknown_kind_and_a_bad_time
    data = JSON.parse(build_message.to_json)

    assert_raises(Keryx::Error) { Keryx::Message.from_json(JSON.generate(data.merge('kind' => 'memo'))) }
    assert_raises(Keryx::Error) { Keryx::Message.from_json(JSON.generate(data.merge('created_at' => 'today'))) }
  end

  def test_from_json_rejects_fields_of_the_wrong_type_as_a_keryx_error
    data = JSON.parse(build_message.to_json)

    %w[from to created_at due_at in_reply_to].each do |field|
      assert_raises(Keryx::Error, field) { Keryx::Message.from_json(JSON.generate(data.merge(field => 42))) }
    end
  end

  def test_overdue_applies_to_requests_past_their_deadline
    assert build_message.overdue?(CREATED + 1801)
    refute build_message.overdue?(CREATED + 1799)
    refute build_message(due_at: nil).overdue?(CREATED + 9999)
    refute build_message(kind: 'message').overdue?(CREATED + 9999)
  end

  def test_only_the_recipients_reply_in_the_thread_answers_a_request
    request = build_message
    reply = build_message(id: '01JB8Y2Q7M0000000000000001', kind: 'reply', from: 'rev-1.dev@athena',
                          to: 'orq.dev@athena', in_reply_to: request.id, due_at: nil)

    assert reply.answers?(request)
    refute reply.with(kind: 'message').answers?(request)
    refute reply.with(from: 'eve.dev@athena').answers?(request)
    refute reply.with(to: 'eve.dev@athena').answers?(request)
    refute reply.with(thread: reply.id).answers?(request)
    refute reply.answers?(request.with(kind: 'message'))
  end

  def test_only_the_recipients_message_in_the_thread_takes_a_request
    request = build_message
    taken = build_message(id: '01JB8Y2Q7M0000000000000001', kind: 'message', from: 'rev-1.dev@athena',
                          to: 'orq.dev@athena', in_reply_to: request.id, due_at: nil)

    assert taken.takes?(request)
    refute taken.answers?(request)
    { kind: 'reply', from: 'orq.dev@athena', to: 'rev-1.dev@athena', thread: taken.id, in_reply_to: taken.id }
      .each { |field, value| refute taken.with(field => value).takes?(request), field }
    refute taken.takes?(request.with(kind: 'message'))
  end

  def test_only_the_senders_withdrawal_in_the_thread_withdraws_a_request
    request = build_message
    withdrawal = build_message(id: '01JB8Y2Q7M0000000000000001', kind: 'withdrawal', in_reply_to: request.id,
                               due_at: nil)

    assert withdrawal.withdraws?(request)
    refute withdrawal.answers?(request)
    { kind: 'reply', from: 'eve.dev@athena', to: 'eve.dev@athena', thread: withdrawal.id, in_reply_to: withdrawal.id }
      .each { |field, value| refute withdrawal.with(field => value).withdraws?(request), field }
    refute withdrawal.withdraws?(request.with(kind: 'message'))
    assert_equal withdrawal, Keryx::Message.from_json(withdrawal.to_json)
  end

  def test_summary_is_the_first_line_with_text_made_safe_and_cut
    assert_equal 'Review PR #448', build_message.summary
    assert_equal 'red ^[[31m', build_message(body: "\n  red \e[31m\n").summary
    assert_equal 'abcdefg...', build_message(body: 'abcdefghijklmnop').summary(10)
  end

  def test_a_context_stamp_round_trips_and_an_unstamped_message_writes_none
    stamped = build_message(context: Keryx::Context.new(used: 137_000, window: 258_400))

    assert_equal stamped, Keryx::Message.from_json(stamped.to_json)
    assert_equal({ 'used' => 137_000, 'window' => 258_400 }, JSON.parse(stamped.to_json)['context'])
    refute JSON.parse(build_message.to_json).key?('context')
  end

  def test_a_stamp_or_a_field_this_build_does_not_know_never_refuses_the_message
    data = JSON.parse(build_message.to_json)

    [{ 'context' => 'big' }, { 'context' => { 'used' => '5' } }, { 'context' => { 'used' => 5, 'window' => -1 } },
     { 'context' => nil }, { 'ceiling' => 5, 'mood' => 'calm' }].each do |extra|
      assert_equal build_message, Keryx::Message.from_json(JSON.generate(data.merge(extra))), extra.inspect
    end
    stamped = Keryx::Message.from_json(JSON.generate(data.merge('context' => { 'used' => 9, 'share' => 1 })))

    assert_equal Keryx::Context.new(used: 9, window: nil), stamped.context
  end
end
