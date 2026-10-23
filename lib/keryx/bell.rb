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
    NOBODY = 'no session holds the address'
    # Claude Code holds typed text until its current step ends, Codex steers the turn with it, Cursor queues it.
    TYPABLE = %w[idle done working].freeze
    DIALOG = Regexp.union(
      /held (peer )?message/i, /deliver this message/i, /hooks need review/i, /trust (this|the) (workspace|folder)/i,
      /do you (trust|want)/i, %r{\((y|yes)/(n|no)\)}i, %r{\[y/n\]}i, /enter (to )?(select|confirm)/i, /press enter/i,
      /allow (this|once|always)/i, /trust all and continue/i, /continue without trusting/i
    )
    # The marker before the selected option: Codex's, Claude Code's and Cursor's. An ASCII ">" is a prompt.
    MARKER = /\A\s*[\u203a\u276f\u25b6]\s*/
    # A number with its dot, a key in brackets, or a Yes or No that ends the line or comes before a comma.
    LABEL = /\G(\d+\.(?!\d)|\[\w\]|(Yes|No)(?=,|\s*\z))/
    # The footer a dialog ends with, such as Codex's "enter confirm" and "esc skip", unlike code on the screen.
    SQUEEZED_FOOTER = Regexp.union(/enter(to)?(select|confirm)\W{1,3}esc(to)?(skip|cancel|exit)/i,
                                   /\u00b7esc(to)?(skip|cancel|exit)/i, /entertoselect,orpress/i)
    # Words do not fit on lines this short, so such a screen cannot show a dialog's options or its footer.
    CRAMPED_CHARACTERS = 3
    CRAMPED_LINES = 4
    BOX_DRAWING = /[\u2500-\u257f]/
    OBSTACLES = { dialog: 'the screen shows a dialog',
                  cramped: 'the pane is too narrow to tell whether it shows a dialog' }.freeze

    # A narrow pane wraps a dialog over several lines, often inside a box, so its phrases are matched on the lines
    # joined, its options line by line, and its footer with no spaces at all, whatever the width.
    def self.dialog?(screen)
      lines = lines(screen)
      DIALOG.match?(lines.join(' ').split.join(' ')) || options?(lines) ||
        SQUEEZED_FOOTER.match?(lines.join.gsub(/\s+/, ''))
    end

    def self.cramped?(screen)
      text = lines(screen).map { it.gsub(/\s+/, '') }.reject(&:empty?)
      text.size >= CRAMPED_LINES && text.all? { it.size <= CRAMPED_CHARACTERS }
    end

    # What keeps a bell from typing into a screen, as a key of OBSTACLES, or nil.
    def self.obstacle(screen)
      return :dialog if dialog?(screen)

      :cramped if cramped?(screen)
    end

    # A marked option and, before a blank line, another option at the same column.
    def self.options?(lines)
      lines.each_with_index.any? do |line, index|
        column = MARKER.match(line)&.end(0)
        next false unless column && LABEL.match?(line, column)

        lines[(index + 1)..].take_while { !it.strip.empty? }.any? do |other|
          other[0, column].strip.empty? && LABEL.match?(other, column)
        end
      end
    end

    def self.lines(screen) = screen.to_s.gsub(BOX_DRAWING, ' ').lines.map(&:chomp)
    private_class_method :options?, :lines

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
      return outcome(ABSENT, nil, NOBODY) unless occupant
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

      obstacle = Bell.obstacle(screen)
      return outcome(DEFERRED, 'herdr', OBSTACLES.fetch(obstacle)) if obstacle

      untypable(occupant) || typed(@herdr.prompt(socket, pane, text))
    end

    # Reading the screen can take seconds and herdr types into a pane, not a session, so the pane is looked at again.
    def untypable(occupant)
      seen = @lookout.in_pane(occupant)
      return unseen(seen) unless seen.there?

      outcome(DEFERRED, 'herdr', "the agent is #{seen.agent.status}") unless TYPABLE.include?(seen.agent.status)
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
