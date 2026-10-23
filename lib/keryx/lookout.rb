# frozen_string_literal: true

require_relative 'herdr'

module Keryx
  # Tells from herdr and the process table whether the session an occupant records still runs where it joined.
  class Lookout
    # there: the pane runs the session. elsewhere: herdr or ps showed it does not. unproven: nothing shows which
    # session the pane runs. unanswered: herdr or ps did not answer.
    Sighting = Data.define(:verdict, :agent, :detail) do
      def there? = verdict == :there
    end
    LABELS = { 'codex' => 'thread', 'cursor' => 'conversation' }.freeze
    NO_PROCESS = 'the session that joined pane %<pane>s recorded no process, as one that joined under an older ' \
                 'keryx; a keryx command it runs from that pane, such as keryx whoami, records it'

    def initialize(herdr:, processes:)
      @herdr = herdr
      @processes = processes
    end

    def in_pane(occupant)
      return sighting(:elsewhere, "#{label(occupant)} #{occupant.session_id} has no herdr pane") unless occupant.herdr?

      pane = occupant.herdr_pane
      agent = @herdr.look(occupant.herdr_socket, pane)
      return sighting(:unanswered, "herdr did not answer for pane #{pane}") if agent.nil?
      return sighting(:elsewhere, "no agent runs in pane #{pane}") if agent == Herdr::NONE
      if agent.kind != occupant.harness
        return sighting(:elsewhere, "pane #{pane} runs #{agent.kind}, not #{occupant.harness}")
      end
      return by_session(occupant, agent) if agent.session

      by_process(occupant, agent)
    end

    # Only what herdr or ps showed counts as gone; a session keryx cannot see at all is unknown.
    def presence(occupant)
      return by_pid(occupant) if occupant.pid
      return :unknown unless occupant.herdr?

      in_pane(occupant).verdict == :elsewhere ? :gone : :live
    end

    private

    # The process only stands in for a session id herdr does not report.
    def by_session(occupant, agent)
      runs = "pane #{occupant.herdr_pane} runs #{label(occupant)} #{agent.session}"
      recorded = occupant.session_id
      return sighting(:unproven, "#{runs}, and the session that joined recorded no #{label(occupant)}") unless recorded
      return sighting(:there, nil, agent) if agent.session == recorded

      sighting(:elsewhere, "#{runs}, not #{recorded}")
    end

    def by_process(occupant, agent)
      pane = occupant.herdr_pane
      return sighting(:unproven, format(NO_PROCESS, pane:)) unless occupant.pid
      unless occupant.started
        return sighting(:unproven, "nothing shows that pane #{pane} still runs the session that joined")
      end

      group = @herdr.foreground(occupant.herdr_socket, pane)
      return sighting(:unanswered, "herdr did not say which process runs in pane #{pane}") unless group
      return sighting(:elsewhere, "pane #{pane} runs process #{group}, not #{occupant.pid}") if group != occupant.pid

      started_as_recorded(occupant, pane) || sighting(:there, nil, agent)
    end

    def started_as_recorded(occupant, pane)
      started = @processes.started(occupant.pid)
      return sighting(:unanswered, "ps did not say when process #{occupant.pid} started") unless started
      return if started == occupant.started

      sighting(:elsewhere, "process #{occupant.pid} in pane #{pane} is not the one that joined")
    end

    def by_pid(occupant)
      return :gone unless @processes.alive?(occupant.pid)
      return :live unless occupant.started

      started = @processes.started(occupant.pid)
      started.nil? || started == occupant.started ? :live : :gone
    end

    def label(occupant) = LABELS.fetch(occupant.harness, 'session')

    def sighting(verdict, detail, agent = nil) = Sighting.new(verdict:, agent:, detail:)
  end
end
