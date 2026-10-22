# frozen_string_literal: true

require 'json'
require 'socket'
require 'time'
require_relative 'herdr'
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
      /do you (trust|want)/i, %r{\((y|yes)/(n|no)\)}i, %r{\[y/n\]}i, /enter to (select|confirm)/i, /press enter/i,
      /allow (this|once|always)/i
    )

    def initialize(store:, herdr:, clock:, claude_socket: ClaudeSocket.new, codex: CodexQueue.new)
      @store = store
      @herdr = herdr
      @clock = clock
      @claude_socket = claude_socket
      @codex = codex
    end

    def ring(name, messages)
      result = attempt(@store.occupant(name), text(messages))
      messages.each { @store.write_receipt(name, it.id, 'bell', result.record) }
      result
    end

    private

    def attempt(occupant, text)
      return outcome(ABSENT, nil, 'no session holds the address') unless occupant

      native = through_harness(occupant, text)
      return native if native && !(native.status == FAILED && occupant.herdr?)
      return through_herdr(occupant, text) if occupant.herdr?

      native || outcome(ABSENT, nil, 'the session has no Claude Code socket, Codex thread or herdr pane')
    end

    def through_harness(occupant, text)
      if occupant.claude_socket
        through_claude(occupant.claude_socket, text)
      elsif occupant.harness == 'codex' && occupant.session_id
        through_codex(occupant.session_id, text)
      end
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
      socket = occupant.herdr_socket
      pane = occupant.herdr_pane
      agent = @herdr.agent(socket, pane)
      return outcome(FAILED, 'herdr', "no agent in pane #{pane}") unless agent
      return outcome(DEFERRED, 'herdr', "the agent is #{agent.status}") unless TYPABLE.include?(agent.status)
      return outcome(DEFERRED, 'herdr', 'the screen shows a dialog') if DIALOG.match?(@herdr.screen(socket, pane).to_s)

      typed(@herdr.prompt(socket, pane, text))
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
