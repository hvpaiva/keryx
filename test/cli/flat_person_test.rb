# frozen_string_literal: true

require 'test_helper'

# A person who used keryx before team names keeps the address the others write to, from a terminal and from a page
# that acts for that person, until it is retired.
class FlatPersonTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers
  include FlatAddresses

  # As the page of a person does: --as with the bare name from a process with no session and no USER.
  def test_a_page_acts_as_a_flat_address_by_its_bare_name_with_no_session_and_no_user
    unheld('hvpaiva')
    rev = join_claude('rev-1.dev', 222)
    keryx('ask', 'hvpaiva@athena', 'Approve the plan?', env: rev)
    page = ->(*argv, input: '') { keryx('--as', 'hvpaiva', *argv, env: { 'USER' => nil }, input:) }
    whoami, inbox, status, who = [%w[whoami], %w[inbox --all], %w[status], %w[who]].map do |argv|
      JSON.parse(page.call(*argv, '-o', 'json').out)
    end
    id = inbox.first['id']

    assert_equal ['hvpaiva@athena', [['Approve the plan?', 'hvpaiva@athena']]],
                 [whoami['address'], inbox.map { it.values_at('body', 'to') }]
    assert_equal([id], status['open_requests'].select { it['to'] == 'hvpaiva@athena' }.map { it['id'] })
    assert_includes who['addresses'].map { it['address'] }, 'hvpaiva@athena'
    assert_equal 'Approve the plan?', JSON.parse(page.call('read', id, '-o', 'json').out)['body']
  end

  def test_a_page_answers_and_writes_as_a_flat_address_with_its_text_on_standard_input
    unheld('hvpaiva')
    rev = join_claude('rev-1.dev', 222)
    keryx('ask', 'hvpaiva@athena', 'Approve the plan?', env: rev)
    id = JSON.parse(keryx('inbox', '-o', 'json', '--as', 'hvpaiva').out).first['id']
    page = ->(*argv, text) { keryx(*argv, '--file', '-', env: { 'USER' => nil }, input: text) }
    sent = [page.call('--as', 'hvpaiva', 'reply', id, 'Approved'),
            page.call('--as', 'hvpaiva', 'send', 'rev-1.dev@athena', 'FYI'),
            page.call('--as', 'hvpaiva@athena', 'ask', 'rev-1', '--within', '30m', 'Status?')]

    assert_equal([[0, true]] * 3, sent.map { [it.status, it.out.match?(/\b[0-9A-HJKMNP-TV-Z]{26}\b/)] })
    assert_equal([%w[hvpaiva@athena message], %w[hvpaiva@athena reply], %w[hvpaiva@athena request]],
                 store.mailbox('rev-1.dev').map { [it.message.from, it.message.kind] }.sort)
  end

  def test_a_plain_terminal_acts_as_the_flat_person_address_until_it_is_retired
    unheld('person')
    before = keryx('whoami').out.lines.first
    retired = keryx('retire', 'person')
    after = keryx('whoami').out.lines.first

    assert_equal ["person@athena\n", 0, "person.local@athena\n"], [before, retired.status, after]
    assert_match(/cannot be retired/, keryx('retire', 'person.local').err)
  end

  def test_mail_to_the_flat_name_of_the_person_creates_that_address_as_before_team_names
    rev = join_claude('rev-1.dev', 222)
    sent = keryx('send', 'person@athena', 'hello', env: rev)

    assert_equal [0, ''], [sent.status, sent.err]
    assert_equal ['person', ['hello']], [store.address('person').name, store.mailbox('person').map { it.message.body }]
    assert_equal "person@athena\n", keryx('whoami').out.lines.first
  end
end
