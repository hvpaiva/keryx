# frozen_string_literal: true

require 'test_helper'

class SpawnerTest < Minitest::Test
  include TempDir
  include Factory

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

  def spawner(store, notices = [])
    Keryx::Spawner.new(herdr: FakeHerdr.new, store:, socket: '/h.sock', clock: -> { NOW }, sleeper: ->(_) {},
                       notice: ->(text) { notices << text })
  end

  def test_the_director_is_recorded_for_the_harness_spawn_starts_in_its_pane
    store = Keryx::Store.new(tmp('state'))
    store.create_address('impl')
    spawner(store).direct('impl', 'w1:p2', 'codex', 'orq')

    assert_equal Keryx::Spawned.new(director: 'orq', harness: 'codex', herdr_socket: '/h.sock', herdr_pane: 'w1:p2'),
                 store.spawned('impl')
  end

  def test_a_director_spawn_cannot_record_is_a_notice
    store = Keryx::Store.new(tmp('state'))
    store.define_singleton_method(:record_spawned) { |*| raise Errno::ENOSPC, 'spawned' }
    notices = []
    spawner(store, notices).direct('impl', 'w1:p2', 'codex', 'orq')

    assert_equal ['spawn could not record orq as the director of impl: No space left on device - spawned.'], notices
  end
end
