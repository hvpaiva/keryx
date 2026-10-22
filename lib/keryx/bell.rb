# frozen_string_literal: true

require 'json'
require 'socket'
require 'time'
require_relative 'herdr'

module Keryx
  # Tells the session holding an address that mail arrived. The message itself stays in the
  # mailbox; the bell only says it is there, so ringing twice is harmless and a bell lost on the
  # way loses nothing. It carries no part of the body, so a sender cannot use it to type
  # instructions into another session.
  #
  # Claude Code sessions are rung through their peer socket, which delivers between tool calls
  # without touching the keyboard. Anything else in a herdr pane is rung by typing into it, and
  # only when nothing on the screen looks like a dialog the typing could answer.
  class Bell
    Result = Data.define(:status, :channel, :detail, :at) do
      def record = { 'status' => status, 'channel' => channel, 'detail' => detail, 'at' => at.utc.iso8601 }
    end

    RUNG = 'rung'
    DEFERRED = 'deferred'
    FAILED = 'failed'
    ABSENT = 'absent'
    # herdr states in which typed text reaches the agent's input: Claude Code queues it for the
    # end of the current step and Codex steers the running turn with it.
    TYPABLE = %w[idle done working].freeze
    DIALOG = Regexp.union(
      /held (peer )?message/i, /deliver this message/i, /hooks need review/i, /trust (this|the) (workspace|folder)/i,
      /do you (trust|want)/i, %r{\((y|yes)/(n|no)\)}i, %r{\[y/n\]}i, /enter to (select|confirm)/i, /press enter/i,
      /allow (this|once|always)/i
    )

    def initialize(store:, herdr:, clock:, claude_socket: ClaudeSocket.new)
      @store = store
      @herdr = herdr
      @clock = clock
      @claude_socket = claude_socket
    end

    # Rings once for `messages`, all unread in the mailbox of `name`, and records the result
    # against each of them.
    def ring(name, messages)
      result = attempt(@store.occupant(name), text(messages))
      messages.each { @store.write_receipt(name, it.id, 'bell', result.record) }
      result
    end

    private

    def attempt(occupant, text)
      return outcome(ABSENT, nil, 'no session holds the address') unless occupant

      if occupant.claude_socket
        result = through_claude(occupant.claude_socket, text)
        return result unless result.status == FAILED && occupant.herdr?
      end
      return through_herdr(occupant, text) if occupant.herdr?

      result || outcome(ABSENT, nil, 'the session has neither a Claude Code socket nor a herdr pane')
    end

    def through_claude(path, text)
      @claude_socket.post(path, text)
      outcome(RUNG, 'claude', nil)
    rescue SystemCallError, IOError => e
      outcome(FAILED, 'claude', "socket #{path}: #{e.message.split(' - ').first}")
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

    # Claude Code accepts one JSON line per connection on its peer socket.
    class ClaudeSocket
      def post(path, text)
        UNIXSocket.open(path) do |socket|
          socket.write("#{JSON.generate('type' => 'user', 'message' => { 'role' => 'user', 'content' => text })}\n")
          socket.close_write
        end
      end
    end
  end
end
