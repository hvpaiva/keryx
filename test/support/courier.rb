# frozen_string_literal: true

require_relative 'files'

module CourierHelpers
  LATER = Factory::NOW + 3600

  class QuietBell
    def ring(*) = Keryx::Bell::Result.new(status: 'rung', channel: 'test', detail: nil, at: Factory::NOW)
  end

  class Meter
    attr_reader :figures, :reads

    def initialize
      @figures = {}
      @reads = []
    end

    def read(occupant)
      @reads << occupant.session_id
      figures[occupant.session_id]&.then { Keryx::Context.new(used: it, window: nil) }
    end
  end

  def store
    @store ||= Keryx::Store.new(tmp('state')).tap { |box| %w[orq.dev rev-1.dev].each { box.create_address(it) } }
  end

  def meter = @meter ||= Meter.new

  def postman
    @postman ||= Keryx::Postman.new(store:, bell: QuietBell.new, forwarder: nil, host: 'athena', clock: -> { LATER },
                                    person: 'person.local')
  end

  def rosters = @rosters ||= []

  def meters = @meters ||= []

  def courier = @courier ||= build_courier

  # The herdr the roster and the courier read, so a test shows a pane to both.
  def fake_herdr = @fake_herdr ||= FakeHerdr.new

  def impl(ceiling: 125_000, **fields)
    store.create_address('impl.dev')
    build_occupant(session_id: 'session-impl', ceiling:, **fields).tap { store.bind('impl.dev', it) }
  end

  def told = ->(round) { round.context.map { [it.recipient, it.stage] } }

  def build_courier(clock: -> { LATER }, measure: meter, box: store, mail: postman)
    Keryx::Courier.new(
      store: box, bell: QuietBell.new, postman: mail, host: 'athena', clock:, herdr: fake_herdr,
      meter: -> { measure.tap { meters << it } },
      forwarder: Keryx::Forwarder.new(store: box, remote: nil, clock: -> { LATER }),
      roster: lambda do
        lookout = Keryx::Lookout.new(herdr: fake_herdr, processes: CLIHelpers::FakeProcesses.new([]))
        Keryx::Roster.new(store: box, herdr: fake_herdr, lookout:).tap { rosters << it }
      end
    )
  end
end
