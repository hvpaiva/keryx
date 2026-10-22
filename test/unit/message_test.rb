# frozen_string_literal: true

require 'test_helper'

class MessageTest < Minitest::Test
  CREATED = Time.utc(2026, 10, 22, 17, 0, 0)

  def build_message(**overrides)
    Keryx::Message.new(id: '01JB8Y2Q7M0000000000000000', kind: 'request', from: 'orq@athena', to: 'rev-1@athena',
                       thread: '01JB8Y2Q7M0000000000000000', in_reply_to: nil, created_at: CREATED,
                       due_at: CREATED + 1800, body: "Review PR #448\n\nFocus on the retry path.", **overrides)
  end

  def test_json_round_trips_every_field
    original = build_message

    assert_equal original, Keryx::Message.from_json(original.to_json)
  end

  def test_json_carries_the_format_version_and_utc_times
    data = JSON.parse(build_message(created_at: Time.new(2026, 10, 22, 14, 0, 0, '-03:00')).to_json)

    assert_equal 1, data['keryx']
    assert_equal '2026-10-22T17:00:00Z', data['created_at']
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
    reply = build_message(id: '01JB8Y2Q7M0000000000000001', kind: 'reply', from: 'rev-1@athena', to: 'orq@athena',
                          in_reply_to: request.id, due_at: nil)

    assert reply.answers?(request)
    refute reply.with(kind: 'message').answers?(request)
    refute reply.with(from: 'eve@athena').answers?(request)
    refute reply.with(to: 'eve@athena').answers?(request)
    refute reply.with(thread: reply.id).answers?(request)
    refute reply.answers?(request.with(kind: 'message'))
  end

  def test_summary_is_the_first_line_with_text_made_safe_and_cut
    assert_equal 'Review PR #448', build_message.summary
    assert_equal 'red ^[[31m', build_message(body: "\n  red \e[31m\n").summary
    assert_equal 'abcdefg...', build_message(body: 'abcdefghijklmnop').summary(10)
  end
end
