# frozen_string_literal: true

require 'json'
require 'socket'
require 'time'
require_relative 'herdr'
require_relative 'lookout'
require_relative 'processes'
require_relative 'runner'
require_relative 'text'

module Keryx
  class Bell
    Result = Data.define(:status, :channel, :detail, :at, :obstacle, :evidence) do
      # The obstacle and the evidence of the Reading that deferred a bell typed through herdr, the obstacle's key as a
      # string, and nil for any other outcome.
      def initialize(obstacle: nil, evidence: nil, **) = super(obstacle: obstacle&.to_s, evidence:, **)

      def record = to_h.transform_keys(&:to_s).merge('at' => at.utc.iso8601)
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
    # The prompt before Codex's, Claude Code's and Cursor's composer, the line a dialog takes the place of.
    COMPOSER = /\A\s*[\u203a\u276f\u2192]\s*/
    # The box above Cursor's composer that lists the follow-ups it queued, from its title to its bottom border.
    FOLLOW_UPS = /\A\s*\u250c\u2500*\s*follow-ups/
    BOTTOM_BORDER = /\A\s*\u2514\u2500*\u2518/
    # A line inside a box, between its side borders.
    FRAMED = /\A\s*\u2502.*\u2502\s*\z/
    # The footer of that box, with no spaces, while one of its messages is open for editing and holds the focus.
    EDITING = /editing\u00b7enterdone\u00b7escclose/i
    # The longest evidence a deferral quotes, since a bell's receipt reaches the sender, on any machine.
    EVIDENCE_CHARACTERS = 60
    OBSTACLES = { dialog: 'the screen shows a dialog', editor: 'the screen shows a queued message being edited',
                  cramped: 'the pane is too narrow to tell whether it shows a dialog' }.freeze

    # An obstacle, as a key of OBSTACLES or nil, what on the screen showed it and where. The evidence holds only the
    # words keryx's own patterns matched, never the rest of the screen, and is nil for a marked option, whose place
    # alone is given so that nothing of the option is quoted.
    Reading = Data.define(:obstacle, :evidence, :place) do
      def note = place ? "#{OBSTACLES.fetch(obstacle)} (#{shown})" : OBSTACLES.fetch(obstacle)

      def shown = evidence ? %("#{evidence}", #{place}) : place
    end
    Word = Data.define(:text, :row, :column)

    # A narrow pane wraps a dialog over several lines, often inside a box, so its phrases are matched on the lines
    # joined, its options line by line, and its footer with no spaces at all, whatever the width. A dialog takes the
    # place of the harness's composer, so what shows above a composer is its transcript, and only the lines below the
    # last composer are read. Cursor's follow-ups box ends with a footer like a dialog's, so it is never read, unless
    # one of its messages is being edited, which takes the focus from the composer drawn below it. A message taller
    # than the pane puts the box's title above the screen, so that footer counts in the frame the screen starts with.
    def self.reading(screen)
      lines = lines(screen)
      raw = screen.to_s.lines.map(&:chomp)
      box = follow_ups(raw)
      editing = footer(lines, [*cut_off(raw), *box], EDITING)
      return Reading.new(obstacle: :editor, **editing) if editing

      dialog = sighting(lines.each_with_index.map { |line, row| box.cover?(row) ? '' : line })
      return Reading.new(obstacle: :dialog, **dialog) if dialog

      Reading.new(obstacle: (:cramped if cramped?(screen)), evidence: nil, place: nil)
    end

    def self.cramped?(screen)
      text = lines(screen).map { it.gsub(/\s+/, '') }.reject(&:empty?)
      text.size >= CRAMPED_LINES && text.all? { it.size <= CRAMPED_CHARACTERS }
    end

    # What keeps a bell from typing into a screen, as a key of OBSTACLES, or nil.
    def self.obstacle(screen) = reading(screen).obstacle

    # The last line with a prompt that marks no option and has no line beside it at its text's column, as the entries
    # of a menu have.
    def self.composer(lines)
      lines.each_index.reverse_each.find do |row|
        column = COMPOSER.match(lines[row])&.end(0)
        column && !LABEL.match?(lines[row], column) &&
          [row - 1, row + 1].none? { it >= 0 && lines[it]&.index(/\S/) == column }
      end
    end

    # The rows of the last follow-ups box, if any, through its bottom border or the last line when the border is below
    # the screen, found on the screen as herdr gave it since the lines the rules read drop the box drawing of its frame.
    def self.follow_ups(raw)
      top = raw.rindex { FOLLOW_UPS.match?(it) } or return 0...0
      bottom = ((top + 1)...raw.size).find { BOTTOM_BORDER.match?(raw[it]) }
      top..(bottom || (raw.size - 1))
    end

    # The framed lines the screen starts with, a box whose top is above the screen. It may be the follow-ups box, but a
    # dialog's box can be cut the same way, so these lines are only searched for the editing footer, never dropped.
    def self.cut_off(raw) = 0...(raw.index { !FRAMED.match?(it) } || raw.size)

    # What shows a dialog on the lines below the last composer, or on all of them when no composer shows.
    def self.sighting(lines)
      rows = (composer(lines)&.succ || 0)...lines.size
      phrase(lines, rows) || option(lines, rows) || footer(lines, rows)
    end

    def self.phrase(lines, rows)
      words = words(lines, rows)
      match = DIALOG.match(words.map(&:text).join(' ')) or return
      quote(lines, words, ' ', match)
    end

    def self.footer(lines, rows, pattern = SQUEEZED_FOOTER)
      words = words(lines, rows)
      match = pattern.match(words.map(&:text).join) or return
      quote(lines, words, '', match)
    end

    def self.option(lines, rows)
      row = rows.find { option?(lines, it) } or return
      { evidence: nil, place: "a marked option on line #{row + 1} of #{lines.size}" }
    end

    # A marked option and, before a blank line, another option at the same column.
    def self.option?(lines, row)
      column = MARKER.match(lines[row])&.end(0)
      return false unless column && LABEL.match?(lines[row], column)

      lines[(row + 1)..].take_while { !it.strip.empty? }.any? do |other|
        other[0, column].strip.empty? && LABEL.match?(other, column)
      end
    end

    def self.words(lines, rows)
      rows.flat_map do |row|
        lines[row].to_enum(:scan, /\S+/).map { Word.new(text: it, row:, column: Regexp.last_match.begin(0)) }
      end
    end

    # The screen's text from the first character the match took to its last, which holds nothing but the match and
    # the blanks between its characters, with the line it starts on.
    def self.quote(lines, words, gap, match)
      first, last = [match.begin(0), match.end(0) - 1].map { spot(words, gap, it) }
      shown = (first.row..last.row).map do |row|
        lines[row][(row == first.row ? first.column : 0)..(row == last.row ? last.column : -1)]
      end
      { evidence: Text.plain(shown.join(' ').split.join(' '))[0, EVIDENCE_CHARACTERS],
        place: "line #{first.row + 1} of #{lines.size}" }
    end

    # Where the character at offset in the words joined by gap shows on the screen.
    def self.spot(words, gap, offset)
      words.each do |word|
        return word.with(column: word.column + offset) if offset < word.text.size

        offset -= word.text.size + gap.size
      end
    end

    def self.lines(screen) = screen.to_s.gsub(BOX_DRAWING, ' ').lines.map(&:chomp)
    private_class_method :composer, :follow_ups, :cut_off, :sighting, :phrase, :footer, :option, :option?, :words,
                         :quote, :spot, :lines

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
      return outcome(DEFERRED, 'herdr', "the agent is #{agent.status}") unless TYPABLE.include?(agent.status)

      screen = @herdr.screen(occupant.herdr_socket, occupant.herdr_pane)
      return outcome(DEFERRED, 'herdr', 'the screen could not be read') if screen.nil?

      read = Bell.reading(screen)
      return outcome(DEFERRED, 'herdr', read.note, obstacle: read.obstacle, evidence: read.evidence) if read.obstacle

      untypable(occupant) || typed(@herdr.prompt(occupant.herdr_socket, occupant.herdr_pane, text))
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

    def outcome(status, channel, detail, **) = Result.new(status:, channel:, detail:, at: @clock.call, **)

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
