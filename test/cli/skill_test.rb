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
    host = keryx('skill').out.lines.drop_while { !it.include?('NAME@HOST') }.slice_before(/\A- /).first.join

    %w[KERYX_HOST ~/.config/keryx/config hostname ssh].each { assert_includes host, it }
  end

  def test_the_skill_says_how_to_take_a_request_whose_work_goes_on
    answer = keryx('skill').out[/^## Answer every request\n.*?(?=^## )/m]

    assert_includes answer, 'keryx send --re ID TEXT'
    assert_includes answer, 'taken'
  end
end
