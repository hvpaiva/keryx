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

  def store = @store ||= Keryx::Store.new(tmp('state')).tap { |box| %w[orq rev-1].each { box.create_address(it) } }

  def meter = @meter ||= Meter.new

  def postman
    @postman ||= Keryx::Postman.new(store:, bell: QuietBell.new, forwarder: nil, host: 'athena', clock: -> { LATER },
                                    person: 'person')
  end

  def rosters = @rosters ||= []

  def meters = @meters ||= []

  def courier = @courier ||= build_courier

  def build_courier
    Keryx::Courier.new(
      store:, bell: QuietBell.new, postman:, host: 'athena', clock: -> { LATER },
      meter: -> { meter.tap { meters << it } },
      forwarder: Keryx::Forwarder.new(store:, remote: nil, clock: -> { LATER }),
      roster: lambda do
        herdr = FakeHerdr.new
        lookout = Keryx::Lookout.new(herdr:, processes: CLIHelpers::FakeProcesses.new([]))
        Keryx::Roster.new(store:, herdr:, lookout:).tap { rosters << it }
      end
    )
  end
end
