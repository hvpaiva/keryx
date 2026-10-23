# frozen_string_literal: true

require 'test_helper'

class SpawnerTest < Minitest::Test
  include TempDir
  include Factory

  def test_a_tab_herdr_lists_without_panes_is_an_error
    herdr = FakeHerdr.new(panes: [Keryx::Herdr::Pane.new(id: 'w1:p1', tab: 'w1:t1', workspace: 'w1')],
                          tabs: { 'w1' => [Keryx::Herdr::Tab.new(id: 'w1:t2', label: 'agents')] })
    spawner = Keryx::Spawner.new(herdr:, store: nil, socket: '/h.sock', clock: -> { Factory::NOW }, sleeper: ->(_) {},
                                 deadline: Factory::NOW + 60, notice: ->(_) {}, post: ->(*) {}, vacant: ->(*) {})
    error = assert_raises(Keryx::Error) do
      spawner.place('w1:p1', label: 'rev-1.dev', address: 'rev-1.dev@athena', kind: 'claude', split: 'right', tab: 'agents',
                             cwd: '/work', env: {})
    end

    assert_equal 'herdr lists no pane in the tab agents', error.message
  end

  def test_the_smallest_pane_spawn_makes_shows_cursor_dialog_and_footer_lines_whole
    box = Screens.captured.fetch('cursor-120').lines.find { it.include?('Use arrow keys') }
    instruction = box.delete([0x2502].pack('U')).strip
    dot = [0xB7].pack('U')
    model = "  Grok 4.7 256K Extra High #{dot} MAX #{dot} 7.8%"
    mode = 'Run Everything -- INSERT --'
    footer = "#{model}#{' ' * (Keryx::Spawner::MIN_COLUMNS - model.size - mode.size)}#{mode}"

    assert_equal 67, instruction.size
    # The box keeps as many columns after its text as before it: a margin, its border and a padding.
    assert_operator instruction.size + (2 * box.index(instruction)), :<=, Keryx::Spawner::MIN_COLUMNS
    assert_match Keryx::Meter::CURSOR_FOOTER, footer.strip
    assert_equal Keryx::Spawner::MIN_ROWS, Integer(Keryx::Herdr::SCREEN_LINES, 10) + Keryx::Herdr::FOOTER_LINES
  end

  def test_an_error_while_herdr_starts_the_agent_comes_through
    herdr = FakeHerdr.new
    herdr.on_start = ->(*) { raise Keryx::Error, 'herdr: not found' }
    spawner = Keryx::Spawner.new(herdr:, store: Keryx::Store.new(tmp('state')), socket: '/h.sock',
                                 clock: -> { Factory::NOW }, sleeper: ->(_) {}, deadline: Factory::NOW + 60,
                                 notice: ->(_) {}, post: ->(*) {}, vacant: ->(*) {})
    error = assert_raises(Keryx::Error) do
      spawner.run('rev-1.dev', 'rev-1.dev@athena', 'w1:p2', kind: 'claude', arguments: [], before: nil, director: nil,
                                                            prompt: 'Review it')
    end

    assert_equal 'herdr: not found', error.message
  end

  def spawner(store, notices = [])
    Keryx::Spawner.new(herdr: FakeHerdr.new, store:, socket: '/h.sock', clock: -> { NOW }, sleeper: ->(_) {},
                       deadline: NOW + 60, notice: ->(text) { notices << text }, post: ->(*) {}, vacant: ->(*) {})
  end

  def test_the_director_is_recorded_for_the_harness_spawn_starts_in_its_pane
    store = Keryx::Store.new(tmp('state'))
    store.create_address('impl.dev')
    spawner(store).direct('impl.dev', 'w1:p2', 'codex', 'orq.dev')

    assert_equal Keryx::Spawned.new(director: 'orq.dev', harness: 'codex', herdr_socket: '/h.sock', herdr_pane: 'w1:p2'),
                 store.spawned('impl.dev')
  end

  def test_a_director_spawn_cannot_record_is_a_notice
    store = Keryx::Store.new(tmp('state'))
    store.define_singleton_method(:record_spawned) { |*| raise Errno::ENOSPC, 'spawned' }
    notices = []
    spawner(store, notices).direct('impl.dev', 'w1:p2', 'codex', 'orq.dev')

    assert_equal ['spawn could not record orq.dev as the director of impl.dev: No space left on device - spawned.'],
                 notices
  end
end
