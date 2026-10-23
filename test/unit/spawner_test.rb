# frozen_string_literal: true

require 'test_helper'

class SpawnerTest < Minitest::Test
  def test_a_tab_herdr_lists_without_panes_is_an_error
    herdr = FakeHerdr.new(panes: [Keryx::Herdr::Pane.new(id: 'w1:p1', tab: 'w1:t1', workspace: 'w1')],
                          tabs: { 'w1' => [Keryx::Herdr::Tab.new(id: 'w1:t2', label: 'agents')] })
    spawner = Keryx::Spawner.new(herdr:, store: nil, socket: '/h.sock', clock: -> { Factory::NOW }, sleeper: ->(_) {},
                                 notice: ->(_) {})
    error = assert_raises(Keryx::Error) do
      spawner.place('w1:p1', label: 'rev-1', split: 'right', tab: 'agents', cwd: '/work', env: {})
    end

    assert_equal 'herdr lists no pane in the tab agents', error.message
  end

  def test_an_error_while_herdr_starts_the_agent_comes_through
    herdr = FakeHerdr.new
    herdr.on_start = ->(*) { raise Keryx::Error, 'herdr: not found' }
    spawner = Keryx::Spawner.new(herdr:, store: nil, socket: '/h.sock', clock: -> { Factory::NOW }, sleeper: ->(_) {},
                                 notice: ->(_) {})
    error = assert_raises(Keryx::Error) do
      spawner.run('rev-1', 'rev-1@athena', 'w1:p2', kind: 'claude', arguments: [], before: nil,
                                                    deadline: Factory::NOW + 60)
    end

    assert_equal 'herdr: not found', error.message
  end
end
