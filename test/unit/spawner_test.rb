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

  def test_the_director_goes_only_on_the_session_that_spawn_saw_join
    store = Keryx::Store.new(tmp('state'))
    store.create_address('impl')
    seen = build_occupant(harness: 'codex', herdr_pane: 'w1:p2')
    notices = []
    spawner = Keryx::Spawner.new(herdr: FakeHerdr.new, store:, socket: '/h.sock', clock: -> { NOW },
                                 sleeper: ->(_) {}, notice: ->(text) { notices << text })
    store.bind('impl', seen.with(joined_at: NOW + 1))
    spawner.direct('impl', seen, 'orq')

    assert_nil store.occupant('impl').director
    store.bind('impl', seen)
    spawner.direct('impl', seen, 'orq')

    assert_equal 'orq', store.occupant('impl').director
    assert_empty notices
  end

  def test_a_director_spawn_cannot_record_is_a_notice
    store = Keryx::Store.new(tmp('state'))
    store.define_singleton_method(:with_occupants_lock) { |*| raise Keryx::Store::Busy, 'locked' }
    notices = []
    spawner = Keryx::Spawner.new(herdr: FakeHerdr.new, store:, socket: '/h.sock', clock: -> { NOW },
                                 sleeper: ->(_) {}, notice: ->(text) { notices << text })
    spawner.direct('impl', build_occupant, 'orq')

    assert_equal ['impl joined, but spawn could not record orq as its director: locked.'], notices
  end
end
