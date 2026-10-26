# frozen_string_literal: true

require 'test_helper'

class SentTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def setup
    super
    @orq = join_claude('orq.dev', 111)
    @rev = join_claude('rev-1.dev', 222)
  end

  def sent(*argv, env: @orq)
    run = keryx('sent', *argv, '-o', 'json', env:)

    assert_equal ['', 0], [run.err, run.status]
    JSON.parse(run.out)
  end

  def bodies(*argv, env: @orq) = sent(*argv, env:).map { it['body'] }

  def zeus
    alive << 333
    machine('zeus').merge(claude(333)).tap { keryx('join', 'port.dev', env: it) }
  end

  def test_a_message_here_is_delivered_and_read_at_is_the_time_of_its_read_mark
    keryx('send', 'rev-1.dev', 'heads-up', env: @orq)
    id = last_id(@rev)
    unread = sent.last
    # The file system stamps with a coarse clock that can trail Time.now by a tick, and read_at drops the fraction.
    before = (Time.now - 0.1).utc.floor
    keryx('read', id, env: @rev)
    after = Time.now.utc
    read_at = sent.last['read_at']

    assert_equal [id, 'rev-1.dev@athena', 'delivered', nil], unread.values_at('id', 'to', 'delivery', 'read_at')
    assert_includes unread.keys, 'read_at'
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, read_at)
    assert_operator before, :<=, Time.iso8601(read_at)
    assert_operator Time.iso8601(read_at), :<=, after
  end

  def test_a_message_to_another_machine_is_queued_then_forwarded_and_has_no_read_at
    port = zeus
    remote.down << 'zeus'
    keryx('send', 'port.dev@zeus', 'Across', env: @orq)
    queued = sent.last
    remote.down.clear
    keryx('courier', '--once')
    keryx('read', env: port)
    forwarded = sent.last

    assert_equal([['port.dev@zeus', 'queued'], ['port.dev@zeus', 'forwarded']],
                 [queued, forwarded].map { it.values_at('to', 'delivery') })
    assert_equal([false, false], [queued, forwarded].map { it.key?('read_at') })
  end

  # A refusal while the sender waits leaves nothing in the outbox; one the courier meets stays in refused/.
  def test_a_message_the_other_machine_refused_lists_as_refused
    zeus
    remote.down << 'zeus'
    keryx('send', 'ghost.dev@zeus', 'Nobody there', env: @orq)
    remote.down.clear
    keryx('courier', '--once')

    assert_equal([%w[ghost.dev@zeus refused]], sent.map { it.values_at('to', 'delivery') })
  end

  # orq takes rev's question with send --re and answers it, then writes to impl and to rev outside the thread.
  def threads
    join_claude('impl.dev', 333)
    keryx('ask', 'orq.dev', 'Which branch?', env: @rev)
    question = last_id(@orq)
    clock.advance(1)
    keryx('send', '--re', question, 'On it', env: @orq)
    taken = last_id(@rev)
    [['reply', question, 'main'], ['send', 'impl', 'Start on the port'], ['send', 'rev-1.dev', 'Another thread']]
      .each do |argv|
        clock.advance(1)
        keryx(*argv, env: @orq)
      end
    [question, taken]
  end

  def test_id_thread_and_to_each_narrow_the_list_and_combine
    question, taken = threads

    assert_equal ['On it'], bodies('--id', taken.downcase)
    assert_equal ['On it', 'main'], bodies('--thread', question)
    assert_equal ['Start on the port'], bodies('--to', 'impl')
    assert_equal ['On it', 'main', 'Another thread'], bodies('--to', 'rev-1.dev@athena')
    assert_equal ['On it'], bodies('--thread', question, '--to', 'rev-1.dev', '--id', taken[0, 20])
    assert_empty bodies('--thread', question, '--to', 'impl')
  end

  def test_a_prefix_shorter_than_four_characters_is_a_usage_error
    %w[--id --thread].each do |option|
      run = keryx('sent', option, '01J', env: @orq)

      assert_equal [2, "error: message id \"01J\" is too short; give at least 4 characters\n" \
                       "Run 'keryx sent --help' for usage.\n"], [run.status, run.err], option
    end
  end

  def test_only_what_the_address_sent_from_this_machine_is_listed
    keryx('send', 'orq.dev', 'From rev', env: @rev)
    store.deliver('rev-1.dev', build_message(from: 'orq.dev@zeus', to: 'rev-1.dev@athena', body: 'From orq on zeus'))
    keryx('send', 'rev-1.dev', 'From orq here', env: @orq)

    assert_equal ['From orq here'], bodies
    assert_equal ['From rev'], bodies(env: @rev)
  end

  def test_a_plain_terminal_acting_as_its_person_lists_what_that_address_sent
    keryx('send', 'rev-1.dev', 'From the terminal')
    keryx('send', 'rev-1.dev', 'From orq', env: @orq)

    assert_equal([['person.local@athena', 'From the terminal']],
                 sent('--as', 'person.local', env: {}).map { it.values_at('from', 'body') })
  end

  def test_a_withdrawal_and_a_reply_list_with_the_request_they_name
    keryx('ask', 'rev-1.dev', 'Review it', env: @orq)
    request = last_id(@rev)
    clock.advance(1)
    keryx('withdraw', request, env: @orq)
    withdrawal = last_id(@rev)
    keryx('ask', 'orq.dev', 'Which branch?', env: @rev)
    question = last_id(@orq)
    clock.advance(1)
    keryx('reply', question, 'main', env: @orq)
    listed = sent

    assert_equal([['request', request, nil, withdrawal], ['withdrawal', withdrawal, request, nil],
                  ['reply', last_id(@rev), question, nil]],
                 listed.map { it.values_at('kind', 'id', 'in_reply_to', 'withdrawn_by') })
    assert_equal([true, false, false], listed.map { it.key?('withdrawn_by') })
  end

  def test_what_a_displaced_session_sent_lists_under_the_address
    alive << 333
    keryx('join', 'orq.dev', '--force', env: claude(333))
    keryx('send', 'rev-1.dev', 'From the displaced session', env: @orq)
    clock.advance(1)
    keryx('send', 'rev-1.dev', 'From the holder', env: claude(333))
    session = store.outgoing('orq.dev').first

    assert_equal([["orq.dev@athena/#{session}", 'From the displaced session'], ['orq.dev@athena', 'From the holder']],
                 sent(env: claude(333)).map { it.values_at('from', 'body') })
    assert_equal ['From the displaced session', 'From the holder'], bodies(env: @orq)
  end

  def test_a_message_to_itself_lists_once_and_a_retired_mailbox_still_lists
    keryx('send', 'rev-1.dev', 'Before the retire', env: @orq)
    clock.advance(1)
    keryx('send', 'orq.dev', 'A note to self', env: @orq)
    keryx('leave', env: @rev)
    keryx('retire', 'rev-1.dev')

    assert store.retired?('rev-1.dev')
    assert_equal([%w[rev-1.dev@athena delivered], %w[orq.dev@athena delivered]],
                 sent.map { it.values_at('to', 'delivery') })
  end

  def test_the_table_shows_where_each_message_is_and_whether_it_was_read
    keryx('send', 'rev-1.dev', 'Read here', env: @orq)
    keryx('read', last_id(@rev), env: @rev)
    clock.advance(1)
    keryx('send', 'rev-1.dev', 'Unread here', env: @orq)
    remote.down << 'zeus'
    clock.advance(1)
    keryx('ask', 'port.dev@zeus', 'Across', env: @orq)
    out = keryx('sent', env: @orq).out

    assert_match(/^ID +TO +AGE +KIND +DELIVERY +READ +SUMMARY\n/, out)
    assert_match(/ rev-1\.dev@athena +2s +message +delivered +0s +Read here\n/, out)
    assert_match(/ rev-1\.dev@athena +1s +message +delivered +- +Unread here\n/, out)
    assert_match(/ port\.dev@zeus +0s +request +queued +\? +Across\n/, out)
  end

  def test_completion_offers_the_filters_and_addresses_after_to
    complete = ->(*words) { keryx('__complete', 'sent', *words, env: @orq).out.lines(chomp: true) }

    assert_equal %w[--id --thread --to], complete.call('--').grep(/\A--(id|thread|to)\z/)
    assert_equal %w[orq rev-1 orq.dev rev-1.dev], complete.call('--to', '')
    assert_empty complete.call('--id', '')
  end

  def test_an_empty_list_says_so
    keryx('send', 'rev-1.dev', 'heads-up', env: @orq)

    assert_equal "No messages sent by rev-1.dev@athena.\n", keryx('sent', env: @rev).out
    assert_equal "No messages sent by orq.dev@athena match.\n", keryx('sent', '--to', 'orq.dev', env: @orq).out
  end
end
