# frozen_string_literal: true

require 'json'
require 'socket'
require 'time'
require_relative 'herdr'
require_relative 'lookout'
require_relative 'processes'
require_relative 'runner'

module Keryx
  class Bell
    Result = Data.define(:status, :channel, :detail, :at) do
      def record = { 'status' => status, 'channel' => channel, 'detail' => detail, 'at' => at.utc.iso8601 }
    end

    RUNG = 'rung'
    DEFERRED = 'deferred'
    FAILED = 'failed'
    ABSENT = 'absent'
    # Claude Code holds typed text until its current step ends, Codex steers the turn with it, Cursor queues it.
    TYPABLE = %w[idle done working].freeze
    DIALOG = Regexp.union(
      /held (peer )?message/i, /deliver this message/i, /hooks need review/i, /trust (this|the) (workspace|folder)/i,
      /do you (trust|want)/i, %r{\((y|yes)/(n|no)\)}i, %r{\[y/n\]}i, /enter (to )?(select|confirm)/i, /press enter/i,
      /allow (this|once|always)/i, /trust all and continue/i, /continue without trusting/i
    )
    SQUEEZED_DIALOG = Regexp.new(DIALOG.source.delete(' '))
    # The footer a dialog ends with, such as Codex's "enter confirm" and "esc skip", unlike code on the screen.
    SQUEEZED_FOOTER = /enter(to)?(select|confirm)\W{1,3}esc(to)?(skip|cancel|exit)/i
    # The longest words of a dialog, such as "permission", break only in a pane this narrow.
    NARROW_COLUMNS = 12
    BOX_DRAWING = /[\u2500-\u257f]/

    # A narrow pane wraps a dialog over several lines, often inside a box, so the screen is matched as one line. With
    # no spaces at all, a screen too narrow for words is matched against every pattern and any other only its footer.
    def self.dialog?(screen)
      text = screen.to_s.gsub(BOX_DRAWING, ' ')
      return true if DIALOG.match?(text.split.join(' '))

      squeezed = text.lines.all? { it.strip.size <= NARROW_COLUMNS } ? SQUEEZED_DIALOG : SQUEEZED_FOOTER
      squeezed.match?(text.gsub(/\s+/, ''))
    end

    def initialize(store:, herdr:, clock:, claude_socket: ClaudeSocket.new, codex: CodexQueue.new,
                   lookout: Lookout.new(herdr:, processes: Processes.new))
      @store = store
      @herdr = herdr
      @lookout = lookout
      @clock = clock
      @claude_socket = claude_socket
      @codex = codex
    end

    def ring(name, messages)
      result = attempt(@store.occupant(name), text(messages))
      messages.each { @store.write_receipt(name, it.id, 'bell', result.record) }
      result
    end

    # Whether a bell for this occupant would ring or wait to ring again, by the same routing as ring, sending nothing.
    def reaches?(occupant)
      return false unless occupant
      return reachable_pane?(occupant) if occupant.harness == 'codex' && occupant.session_id
      return true if open_socket?(occupant)

      occupant.herdr? && reachable_pane?(occupant)
    end

    private

    def attempt(occupant, text)
      return outcome(ABSENT, nil, 'no session holds the address') unless occupant
      return codex_thread(occupant, text) if occupant.harness == 'codex' && occupant.session_id
      return claude_session(occupant, text) if occupant.claude_socket
      return through_herdr(occupant, text) if occupant.herdr?

      outcome(ABSENT, nil, 'the session has no Claude Code socket, Codex thread or herdr pane')
    end

    def claude_session(occupant, text)
      posted = through_claude(occupant.claude_socket, text)
      posted.status == FAILED && occupant.herdr? ? through_herdr(occupant, text) : posted
    end

    # Codex runs what is queued for any thread it has loaded, and its shared server keeps a thread loaded after
    # the TUI quits, so only a thread herdr shows open in its pane is queued.
    def codex_thread(occupant, text)
      seen = @lookout.in_pane(occupant)
      return unseen(seen) unless seen.there?
      return typed_into(occupant, seen.agent, text) unless seen.agent.session == occupant.session_id

      queued = through_codex(occupant.session_id, text)
      # The queue can take seconds to fail, so the pane is read again before anything is typed into it.
      queued.status == FAILED ? through_herdr(occupant, text) : queued
    end

    def through_claude(path, text)
      @claude_socket.post(path, text)
      outcome(RUNG, 'claude', nil)
    rescue SystemCallError, IOError => e
      outcome(FAILED, 'claude', "socket #{path}: #{e.message.split(' - ').first}")
    end

    def through_codex(thread, text)
      result = @codex.queue(thread, text)
      return outcome(RUNG, 'codex', nil) if result.success

      outcome(FAILED, 'codex', result.err.lines.first.to_s.strip)
    end

    def through_herdr(occupant, text)
      seen = @lookout.in_pane(occupant)
      seen.there? ? typed_into(occupant, seen.agent, text) : unseen(seen)
    end

    def typed_into(occupant, agent, text)
      socket = occupant.herdr_socket
      pane = occupant.herdr_pane
      return outcome(DEFERRED, 'herdr', "the agent is #{agent.status}") unless TYPABLE.include?(agent.status)

      screen = @herdr.screen(socket, pane)
      return outcome(DEFERRED, 'herdr', 'the screen could not be read') if screen.nil?
      return outcome(DEFERRED, 'herdr', 'the screen shows a dialog') if Bell.dialog?(screen)

      typed(@herdr.prompt(socket, pane, text))
    end

    # herdr or ps not answering may pass, so that bell waits to ring again; anything else is not the session.
    def unseen(seen) = outcome(seen.verdict == :unanswered ? DEFERRED : ABSENT, nil, seen.detail)

    def reachable_pane?(occupant) = %i[there unanswered].include?(@lookout.in_pane(occupant).verdict)

    def open_socket?(occupant)
      path = occupant.claude_socket
      !path.nil? && @claude_socket.open?(path) && @lookout.presence(occupant) == :live
    end

    def typed(prompt)
      return outcome(RUNG, 'herdr', nil) if prompt.ok
      return outcome(DEFERRED, 'herdr', 'the agent is blocked') if prompt.code == 'agent_blocked'

      outcome(FAILED, 'herdr', [prompt.code, prompt.detail].compact.join(': '))
    end

    def outcome(status, channel, detail) = Result.new(status:, channel:, detail:, at: @clock.call)

    def text(messages)
      latest = messages.last
      if messages.one?
        "[keryx] New #{latest.kind} for #{latest.to} from #{latest.from} (#{latest.id}). " \
          "Run 'keryx read #{latest.id}' to open it."
      else
        "[keryx] #{messages.size} unread messages for #{latest.to}, the latest a #{latest.kind} from " \
          "#{latest.from}. Run 'keryx inbox' to list them."
      end
    end

    class ClaudeSocket
      def open?(path) = File.socket?(path)

      def post(path, text)
        UNIXSocket.open(path) do |socket|
          socket.write("#{JSON.generate('type' => 'user', 'message' => { 'role' => 'user', 'content' => text })}\n")
          socket.close_write
        end
      end
    end

    class CodexQueue
      def initialize(runner: Runner.new)
        @runner = runner
      end

      def queue(thread, text) = @runner.call(['codex', 'queue', '--thread', thread, '--message', text])
    end
  end
end
