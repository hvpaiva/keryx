# frozen_string_literal: true

require 'test_helper'

# A bell kept from typing into a herdr pane whose composer holds a person's unsent text.
class BellDraftTest < Minitest::Test
  include TempDir
  include Factory
  include BellHelpers

  # The receipt reaches the sender, on any machine, so it says where the person's text shows and never what it says.
  def test_herdr_never_types_into_a_composer_holding_a_person_s_draft_nor_quotes_it
    message = deliver
    store.bind('rev-1.dev', pane_occupant)
    herdr = herdr_with('done', screen: Screens.session('cursor-draft'))
    result = bell(herdr:).ring('rev-1.dev', [message])

    assert_equal ['deferred', 'the screen shows text typed in the composer (line 2 of 6)'],
                 [result.status, result.detail]
    assert_equal ['draft', nil], store.receipt('rev-1.dev', message.id, 'bell').values_at('obstacle', 'evidence')
    assert_empty herdr.prompts
  end
end
