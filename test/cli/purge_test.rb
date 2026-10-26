# frozen_string_literal: true

require 'test_helper'

class PurgeTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def setup
    super
    @orq = join_claude('orq.dev', 111)
    @rev = join_claude('rev-1.dev', 222)
  end

  def asked(recipient, text, env:) = keryx('ask', recipient, text, env:).out[/\AAsked \S+ \((\w{26})\)/, 1]

  def retired
    alive.delete(222)
    result = keryx('retire', 'rev-1.dev')
    raise "retire failed: #{result.err}" unless result.status.zero?
  end

  def purged
    result = keryx('purge', 'rev-1.dev', env: @orq)
    raise "purge failed: #{result.err}" unless result.status.zero?

    result
  end

  def box(*parts) = tmp('state', 'addresses', 'rev-1.dev', *parts)

  def stamp = clock.now.utc.strftime('%Y-%m-%d %H:%M:%S UTC')

  def receipts
    size = Dir.children(box('receipts')).size
    "#{size} receipt#{'s' unless size == 1}"
  end

  # Each entry under ROOT, as lstat sees it: a link by its target, a file by its content, a folder by its name alone.
  def tree(root)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: root).sort.filter_map do |path|
      [path, entry(File.join(root, path))] unless File.basename(path) == '.'
    end
  end

  def entry(path)
    stat = File.lstat(path)
    return [:link, File.readlink(path)] if stat.symlink?

    stat.file? ? File.binread(path) : :folder
  end

  def outside_the_box = tree(tmp('state')).reject { |path, _| path.start_with?('addresses/rev-1.dev') }

  # rev-1.dev asks orq.dev and has its answer, answers a request of orq.dev's it read, and has a message unread. The
  # answer's id is returned.
  def exchange
    question = asked('orq.dev', 'Which branch?', env: @rev)
    clock.advance(1)
    keryx('reply', question, 'main', env: @orq)
    clock.advance(1)
    review = asked('rev-1.dev', 'Review it', env: @orq)
    keryx('read', review, env: @rev)
    keryx('reply', review, 'Done', env: @rev)
    keryx('send', 'rev-1.dev', 'heads-up', env: @orq)
    store.stored('rev-1.dev').map(&:message).find { it.in_reply_to == question }.id
  end

  # A request it sent waits for a reply it cannot get while retired, so the address comes back to withdraw it.
  def withdraw_as_revived(id)
    alive << 333
    keryx('join', 'rev-1.dev', '--revive', env: claude(333))
    keryx('withdraw', id, env: claude(333))
    alive.delete(333)
    keryx('retire', 'rev-1.dev')
  end

  def refusals
    flat = 'names no team, as an address from before team names does, whose folder keryx keeps as the keryx of ' \
           'that time wrote it; purge takes MEMBER.TEAM or MEMBER.TEAM@HOST'
    reserved = 'is in a reserved scope: NAME.local is a person at a terminal, and keryx.system is keryx itself, so ' \
               'purge takes neither'
    { 'rev-1.dev' => "rev-1.dev@athena is not retired; 'keryx retire rev-1.dev' comes first",
      'nobody.dev' => 'no address nobody.dev@athena',
      'rev-1.dev@zeus' => "purge runs on the machine that holds the address; run 'keryx purge rev-1.dev' on zeus",
      'rev-1.dev@athena/abcdef' => 'rev-1.dev@athena/abcdef is one session of rev-1.dev@athena, and purge takes ' \
                                   'only the address itself',
      'person.local' => "person.local@athena #{reserved}", 'keryx.system' => "keryx.system@athena #{reserved}",
      'hvpaiva@athena' => "hvpaiva@athena #{flat}", 'hvpaiva' => "hvpaiva@athena #{flat}" }
  end

  def test_purge_refuses_what_is_not_a_retired_team_address_here_and_changes_nothing
    before = tree(tmp('state'))
    refusals.each do |text, error|
      result = keryx('purge', text, env: @orq)

      assert_equal [1, "error: #{error}\n"], [result.status, result.err], text
    end
    assert_equal before, tree(tmp('state'))
  end

  # A request that reached the address as it was retired stays open, and only its sender settles it.
  def test_purge_refuses_while_requests_wait_either_way_and_says_who_settles_each
    received = asked('rev-1.dev', 'Review PR #448', env: @orq)
    sent = asked('orq.dev', 'Which branch?', env: @rev)
    alive.delete(222)
    store.retire('rev-1.dev', by: 'orq.dev@athena', now: clock.now)
    result = keryx('purge', 'rev-1.dev', env: @orq)

    assert_equal 1, result.status
    assert_equal "error: rev-1.dev@athena has 2 open requests and is purged once none is left: #{received} from " \
                 "orq.dev@athena waits for its answer; its sender settles it with 'keryx withdraw #{received}'; " \
                 "#{sent} it sent to orq.dev@athena waits for a reply, which keryx refuses to a retired address; " \
                 "revive it with 'keryx join rev-1.dev --revive' from a session, withdraw #{sent}, and retire it " \
                 "again\n", result.err
    keryx('withdraw', received, env: @orq)
    withdraw_as_revived(sent)

    assert_equal 0, keryx('purge', 'rev-1.dev', env: @orq).status
  end

  def test_purge_waits_for_the_courier_to_forward_what_the_address_sent
    remote.down << 'zeus'
    keryx('send', 'port.dev@zeus', 'hello', env: @rev)
    retired
    queued = store.outbox.queued('zeus').map(&:id)
    result = keryx('purge', 'rev-1.dev', env: @orq)

    assert_equal [1, "error: rev-1.dev@athena has 1 message waiting in the outbox for zeus (#{queued.first}); " \
                     'purge runs once keryx courier forwarded or refused each, as keryx status shows under NOT ' \
                     "FORWARDED\n"], [result.status, result.err]
    remote.down.clear
    keryx('courier', '--once')

    assert_equal 0, keryx('purge', 'rev-1.dev', env: @orq).status
  end

  def test_purge_removes_the_mail_keeps_the_answers_to_its_requests_and_leaves_other_mailboxes_alone
    answer = exchange
    retired
    others = outside_the_box
    count = receipts
    result = purged

    assert_equal others, outside_the_box
    assert_equal "Purged rev-1.dev@athena, removing 2 messages, 1 read mark, #{count} and 0 files being written, and " \
                 "keeping an answer to a request it sent. Its name stays retired; 'keryx join rev-1.dev --revive' " \
                 "takes it back without that mail.\n", result.out
    assert_equal %w[address.json mail retired.json], Dir.children(box).sort
    assert_equal ["#{answer}.json"], Dir.children(box('mail'))
    assert_empty JSON.parse(keryx('status', '-o', 'json', env: @orq).out)['open_requests']
  end

  def test_purge_marks_when_and_by_which_address_in_the_retirement_record
    retired_at = clock.now.utc.iso8601
    retired
    clock.advance(60)
    purged

    assert_equal({ 'retired_at' => retired_at, 'by' => 'person.local@athena', 'purged_at' => clock.now.utc.iso8601,
                   'purged_by' => 'orq.dev@athena' }, JSON.parse(File.read(box('retired.json'))))
  end

  def test_mail_to_a_purged_address_is_refused_from_here_and_from_another_machine
    retired
    purged
    alive << 333
    zeus = machine('zeus').merge(claude(333))
    keryx('join', 'port.dev', env: zeus)

    assert_equal "error: rev-1.dev@athena is retired; mail to it is refused\n",
                 keryx('send', 'rev-1.dev', 'hello', env: @orq).err
    assert_equal "error: athena refused the message; rev-1.dev@athena is retired; mail to it is refused\n",
                 keryx('send', 'rev-1.dev@athena', 'hello', env: zeus).err
  end

  def test_join_revive_takes_a_purged_address_back_and_says_its_mail_was_purged
    keryx('send', 'rev-1.dev', 'heads-up', env: @orq)
    retired
    purged
    alive << 333

    assert_match(/rev-1.dev@athena is retired; pass --revive/, keryx('join', 'rev-1.dev', env: claude(333)).err)
    revived = keryx('join', 'rev-1.dev', '--revive', env: claude(333))

    assert_equal 0, revived.status
    assert_includes revived.out, "Its mail was purged at #{stamp} by orq.dev@athena, so its mailbox starts empty.\n"
    assert_empty store.stored('rev-1.dev')
    refute store.retired?('rev-1.dev')
  end

  def test_a_dry_run_says_what_purge_would_remove_and_changes_nothing
    keryx('send', 'rev-1.dev', 'heads-up', env: @orq)
    retired
    before = tree(tmp('state'))
    result = keryx('purge', 'rev-1.dev', '--dry-run', env: @orq)

    assert_equal "Purging rev-1.dev@athena would remove 1 message, 0 read marks, #{receipts} and 0 files " \
                 "being written. Nothing was removed.\n", result.out
    assert_equal before, tree(tmp('state'))
  end

  def test_a_second_purge_finishes_one_cut_short_and_a_third_says_it_is_done
    keryx('send', 'rev-1.dev', 'heads-up', env: @orq)
    retired
    mark = store.retired('rev-1.dev').with(purged_at: clock.now, purged_by: 'person.local@athena').record
    File.write(box('retired.json'), JSON.generate(mark))
    cut = stamp
    count = receipts
    clock.advance(60)
    result = purged

    assert_equal "Finished purging rev-1.dev@athena, purged at #{cut} by person.local@athena, removing 1 message, 0 " \
                 "read marks, #{count} and 0 files being written, which a purge cut short left or which arrived " \
                 "after it.\n", result.out
    assert_equal mark, JSON.parse(File.read(box('retired.json')))
    again = keryx('purge', 'rev-1.dev', env: @orq)

    assert_equal [1, "error: rev-1.dev@athena was purged already, at #{cut} by person.local@athena\n"],
                 [again.status, again.err]
  end

  def test_history_lists_what_purge_kept_and_says_when_the_mail_was_purged
    answer = exchange
    retired
    purged
    history = keryx('history', 'rev-1.dev').out

    assert_includes history, answer
    refute_includes history, 'heads-up'
    assert_includes history, "rev-1.dev@athena was purged at #{stamp} by orq.dev@athena; history lists only the " \
                             "answers to the requests it sent, which purge keeps.\n"
    assert_equal([answer], JSON.parse(keryx('history', 'rev-1.dev', '-o', 'json').out).map { it['id'] })
  end

  def test_completion_offers_the_retired_addresses_to_purge
    retired

    assert_equal %w[rev-1.dev], keryx('__complete', 'purge', '', env: @orq).out.lines(chomp: true)
  end
end
