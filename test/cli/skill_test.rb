# frozen_string_literal: true

require 'test_helper'

class SkillTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def test_the_skill_is_a_skill_file
    output = keryx('skill').out

    assert_match(/\A---\nname: keryx\ndescription: .+\n---\n/, output)
    assert_includes output, 'keryx reply ID TEXT'
  end

  def test_the_skill_says_where_the_host_of_an_address_comes_from
    host = keryx('skill').out.lines.drop_while { !it.include?('another machine is') }.slice_before(/\A- /).first.join

    %w[KERYX_HOST ~/.config/keryx/config hostname ssh].each { assert_includes host, it }
  end

  def test_the_skill_says_how_to_take_a_request_whose_work_goes_on
    answer = keryx('skill').out[/^## Answer every request\n.*?(?=^## )/m]

    assert_includes answer, 'keryx send --re ID TEXT'
    assert_includes answer, 'taken'
  end

  def test_the_skill_says_later_work_and_a_persons_request_get_a_commitment_and_then_the_result
    answer = keryx('skill').out[/^## Answer every request\n.*?(?=^## )/m].gsub(/\s+/, ' ')

    assert_includes answer, 'any request for work from a person, whose address is `NAME.local`, is answered at once'
    assert_includes answer, 'with an absolute time and its zone'
    assert_includes answer, "send the result with `keryx send ADDRESS TEXT` to the sender, with the request's id"
  end
end
