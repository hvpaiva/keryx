# frozen_string_literal: true

require 'test_helper'

# Within schema 1 fields are only added, so these tests pin the keys of every -o json output: a change that removes or
# renames one fails here, and raises the schema instead.
class JSONSchemaTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  FIXTURES = File.expand_path('../fixtures/context', __dir__)
  MESSAGE = %w[body created_at due_at from id in_reply_to kind thread to].freeze
  ADDRESS = %w[address ceiling context host last_activity member role session session_address team unread].freeze
  SESSION = %w[ceiling claude_socket cwd director harness herdr_pane herdr_socket joined_at pid session session_id
               started transcript].freeze

  # orq's context is measured, so its request carries context and rev's message does not; orq's bell fails, so rev's
  # message is not rung; zeus is down, so orq's message to it stays queued.
  def setup
    super
    @orq = join_claude('orq.dev', 111, role: 'orchestrator')
    @rev = join_claude('rev-1.dev', 222, role: 'reviewer')
    transcript(111)
    keryx('ask', 'rev-1.dev', 'Review PR #448', '--within', '10m', env: @orq)
    @request = last_id(@rev)
    clock.advance(1)
    sockets.gone << '/tmp/cc-111.sock'
    keryx('send', 'orq.dev', 'heads-up', env: @rev)
    remote.down << 'zeus'
    keryx('send', 'port.ops@zeus', 'Queued for a machine that is down', env: @orq)
  end

  def transcript(pid)
    path = tmp('home', '.claude', 'projects', '-work', "session-#{pid}.jsonl")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, File.read(File.join(FIXTURES, 'claude-transcript.jsonl')).gsub('"session-1"', %("session-#{pid}")))
  end

  def json(*argv, env: {})
    run = keryx(*argv, '-o', 'json', env:)

    assert_equal ['', 0], [run.err, run.status]
    JSON.parse(run.out)
  end

  def keys(record) = record.keys.sort

  def test_who
    who = json('who', '--all')

    assert_equal %w[addresses hidden schema view], keys(who)
    assert_equal 1, who['schema']
    assert_equal [[*ADDRESS, 'harness', 'join'].sort], who['addresses'].map { keys(it) }.uniq
    assert_equal %w[used window], keys(who['addresses'].first['context'])
    assert_equal %w[cwd harness herdr_pane herdr_socket joined_at pid session_id started transcript],
                 keys(who['addresses'].first['join'])
  end

  def test_status
    status = json('status', '--all')

    assert_equal %w[schema view hidden addresses open_requests not_rung not_forwarded], status.keys
    assert_equal [[*ADDRESS, 'waiting'].sort], status['addresses'].map { keys(it) }.uniq
    assert_equal([[*MESSAGE, 'context', 'overdue', 'state'].sort], status['open_requests'].map { keys(it) })
    refute(status['open_requests'].any? { it.key?('withdrawn_by') })
    assert_equal([%w[at bell channel detail evidence from id obstacle to]], status['not_rung'].map { keys(it) })
    assert_equal([%w[attempts detail from id state to]], status['not_forwarded'].map { keys(it) })
  end

  def test_whoami
    whoami = json('whoami', env: @orq)

    assert_equal %w[address host member role schema session session_address team unread], keys(whoami)
    assert_equal SESSION, keys(whoami['session'])
  end

  def test_inbox_gives_schema_in_each_element
    inbox = json('inbox', '--all', env: @rev)

    assert_equal([[*MESSAGE, 'context', 'schema', 'state', 'withdrawn_by'].sort], inbox.map { keys(it) })
    assert_equal([1], inbox.map { it['schema'] })
    assert_equal([%w[schema]], json('inbox', '--all', env: @orq).map { keys(it) - MESSAGE - %w[state] })
  end

  def test_read
    assert_equal [*MESSAGE, 'context', 'schema', 'withdrawn_by'].sort, keys(json('read', @request, env: @rev))
  end

  def test_sent_gives_read_at_only_for_a_recipient_here
    sent = json('sent', env: @orq)

    assert_equal([[*MESSAGE, 'context', 'delivery', 'read_at', 'schema', 'withdrawn_by'].sort,
                  [*MESSAGE, 'context', 'delivery', 'schema'].sort], sent.map { keys(it) })
    assert_equal(%w[delivered queued], sent.map { it['delivery'] })
  end

  def test_history_gives_the_records_of_inbox_and_with_sent_those_of_sent
    keryx('withdraw', @request, env: @orq)
    keryx('leave', env: @rev)
    keryx('retire', 'rev-1.dev', env: @orq)
    history = json('history', 'rev-1.dev')

    assert_equal([[*MESSAGE, 'context', 'schema', 'state', 'withdrawn_by'].sort,
                  [*MESSAGE, 'context', 'schema', 'state'].sort], history.map { keys(it) })
    assert_equal([[*MESSAGE, 'delivery', 'read_at', 'schema'].sort],
                 json('history', 'rev-1.dev', '--sent').map { keys(it) })
  end

  def test_wait
    clock.advance(1)
    keryx('reply', @request, 'Done', env: @rev)

    assert_equal [*MESSAGE, 'schema'].sort, keys(json('wait', @request, env: @orq))
  end

  def test_wiring
    codex = json('wiring', 'codex')

    assert_equal %w[arguments bell environment harness hooks host schema], keys(codex)
    assert_equal %w[entry files trust], keys(codex['hooks'])
    assert_equal %w[pane store through], keys(codex['environment'])
    assert_equal [%w[name set_to]], codex['environment'].values_at('pane', 'store').flatten.map { keys(it) }.uniq
    assert_nil json('wiring', 'claude')['hooks']
  end
end
