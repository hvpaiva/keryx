# frozen_string_literal: true

require 'digest'
require_relative 'bell'
require_relative 'error'
require_relative 'text'

module Keryx
  # A dialog that stops the session spawn started, such as a folder trust or permission question. spawn quotes it once
  # on stderr and once in a message from keryx to the address spawn runs as, and never answers it.
  class Dialog
    LINES = 24
    WIDTH = 160
    # Enough of the first prompt's letters and digits to find where the command herdr typed ends, however the shell
    # quoted it and the pane wrapped it.
    TAIL = 24
    # A box's top border, which starts with its corner, or a horizontal rule across the line.
    TOP = /\A[\u250c-\u250f\u2552-\u2554\u256d]/
    RULE = /\A\u2500+\z/
    CUT = "\u2026"
    CRAMPED = 'is too narrow to tell whether it shows a dialog'
    EDITOR = 'shows a queued message being edited'
    ANSWERED = 'the session joins by itself once it is answered; keryx never answers one'
    # How a director answers a dialog keryx tells it about: at once, unless its human told it not to.
    ANSWER = "keryx never answers a dialog. Answer it now with 'herdr pane send-keys %<pane>s KEY...', unless your " \
             "human has told you not to. Allow once what the session's delegation record grants, never the option " \
             'that changes a setting or stops later prompts, and decline what the record does not grant or reserves ' \
             'to your human. Take it to your human at once, with this text and the pane, only when neither the ' \
             'record nor their standing rules cover it, or when your harness will not let you answer.'

    # A harness that answers a dialog by itself after a while counts down on screen, as in "will automatically deny
    # this request in 0:28", so the count changes every second while the dialog stays the same. Iris reads it so too.
    COUNTDOWN = /\b(?:automatically|auto-?(?:deny|denies|approve|approves|accept|reject))\b/i
    TIMER = /\b\d{1,2}:\d{2}\b|\b\d+\s?s(?:ec(?:onds?)?)?\b/
    # A menu that closes by itself and needs no answer, such as the one Codex shows while it gives a request extra
    # thought.
    NO_ACTION = /no action is required/i

    # The dialog a read of the pane shows below the command herdr typed, as the lines spawn quotes, or nil when it
    # shows none. That command holds the first prompt, whose words could pass for a dialog.
    def self.excerpt(read, prompt)
      lines = below(read, prompt)
      block(lines).filter_map { quoted(it) }.last(LINES) if dialog?(lines)
    end

    # The dialog a read of a joined session's pane shows, as the lines the courier quotes, or nil when it shows none or
    # a menu that needs no answer. The command herdr typed no longer shows, so a dialog with no box top or rule above
    # it is quoted from below the last composer, whose place it takes, and the transcript above stays out.
    def self.shown(read)
      lines = lines_of(read)
      return unless dialog?(lines)

      quote = block(lines, below_composer(lines)).filter_map { quoted(it) }.last(LINES)
      quote unless quote.any? { NO_ACTION.match?(it) }
    end

    # What makes two quotes the same dialog: a moved selection or a countdown's next second makes no new one.
    def self.key(quote)
      steady = quote.map { it.sub(Bell::MARKER, '') }.map { COUNTDOWN.match?(it) ? it.gsub(TIMER, '#') : it }
      Digest::SHA256.hexdigest(steady.join("\n"))
    end

    def self.cramped?(read, prompt) = Bell.cramped?(below(read, prompt).join("\n"))

    # What a read of the pane shows below the command herdr typed, as a key of Bell::OBSTACLES, or nil.
    def self.obstacle(read, prompt) = Bell.obstacle(below(read, prompt).join("\n"))

    # The lines after the one where the typed command ends, which the last letters and digits of the first prompt end.
    def self.below(read, prompt)
      lines = lines_of(read)
      tail = letters(prompt).chars.last(TAIL).join
      pieces = lines.map { letters(it) }
      at = pieces.join.rindex(tail) unless tail.empty?
      return lines unless at

      seen = 0
      lines.drop(pieces.index { (seen += it.size) >= at + tail.size } + 1)
    end

    # From the last box top or rule that still has the dialog below it, else the lines given for none.
    def self.block(lines, otherwise = lines)
      borders = lines.each_index.select { border?(lines[it]) }
      start = borders.reverse.find { dialog?(lines.drop(it + 1)) }
      start ? lines.drop(start + 1) : otherwise
    end

    def self.below_composer(lines)
      row = Bell.composer(lines.map { it.gsub(Bell::BOX_DRAWING, ' ') })
      row ? lines.drop(row + 1) : lines
    end

    def self.lines_of(read)
      String.new(read.to_s, encoding: Encoding::UTF_8).scrub(Text::REPLACEMENT).lines(chomp: true)
    end

    def self.border?(line) = TOP.match?(line.lstrip) || RULE.match?(line.strip)

    def self.quoted(line)
      text = line.gsub(Bell::BOX_DRAWING, ' ').squeeze(' ').strip
      return if text.empty?

      text = Text.plain(text)
      text.size > WIDTH ? "#{text[0, WIDTH - 1]}#{CUT}" : text
    end

    def self.dialog?(lines) = Bell.obstacle(lines.join("\n")) == :dialog
    def self.letters(text) = text.to_s.gsub(/[^[:alnum:]]/, '')
    private_class_method :below, :block, :below_composer, :lines_of, :dialog?, :border?, :quoted, :letters

    def initialize(herdr:, socket:, pane:, address:, director:, prompt:, notice:, post:)
      @herdr = herdr
      @socket = socket
      @pane = pane
      @address = address
      @director = director
      @prompt = prompt
      @notice = notice
      @post = post
      @quoted = nil
      @cramped = false
      @edited = false
    end

    # What a poll found: :dialog when herdr or the screen says a dialog may show, :cramped when the screen is too narrow
    # to tell, :editor when a queued message is being edited, or nil. A dialog is quoted once a read of the pane shows
    # one, and until then each signal reads again.
    def signal(obstacle)
      case obstacle
      when :cramped then cramped
      when :editor then editor
      when :dialog then look unless @quoted
      end
    end

    # The deadline reads the pane again and reports what that read shows, since the pane may have changed since spawn
    # last looked, such as from a folder trust to a permission question, or to no dialog at all.
    def late
      read = @herdr.visible(@socket, @pane) or return unread
      case Dialog.obstacle(read, @prompt)
      when :dialog then "#{waiting}: pane #{@pane} shows the dialog below, and #{ANSWERED}\n" \
                        "#{indented(Dialog.excerpt(read, @prompt))}"
      when :editor then "#{waiting}: pane #{@pane} #{EDITOR}, and the session joins by itself once it is closed"
      when :cramped
        "#{waiting}: pane #{@pane} #{CRAMPED}; look at it, and the session joins by itself once any dialog is answered"
      else idle
      end
    end

    private

    def waiting = "#{@address} has not joined yet"
    def idle = "#{waiting}; look at pane #{@pane}"

    # A dialog quoted earlier is what spawn saw then, and the pane may no longer show it.
    def unread
      return idle unless @quoted

      "#{waiting}: spawn could not read pane #{@pane} again; when it read the pane earlier, the pane showed the " \
        "dialog below, and #{ANSWERED}\n#{indented(@quoted)}"
    end

    def look
      read = @herdr.visible(@socket, @pane) or return
      excerpt = Dialog.excerpt(read, @prompt)
      return quote(excerpt) if excerpt

      cramped if Dialog.cramped?(read, @prompt)
    end

    def quote(excerpt)
      @quoted = excerpt
      text = indented(excerpt)
      @notice.call("Pane #{@pane} shows a dialog, and #{@address} joins once it is answered; keryx never answers " \
                   "one. Its text follows.\n#{text}")
      tell(text) if @director
    end

    def tell(text)
      @post.call(@director, "Pane #{@pane}, where spawn started #{@address}, stops at a dialog, and the session " \
                            "joins once it is answered. Its text follows.\n\n#{text}\n\n#{format(ANSWER, pane: @pane)}")
    rescue Error, SystemCallError => e
      @notice.call("spawn could not tell #{@director} about the dialog in pane #{@pane}: #{e.message}.")
    end

    def cramped
      return if @cramped

      @cramped = true
      @notice.call("Pane #{@pane} #{CRAMPED}, such as a folder trust or permission question. Look at it there; " \
                   'keryx never answers one. The session joins once any dialog is answered.')
    end

    def editor
      return if @edited

      @edited = true
      @notice.call("Pane #{@pane} #{EDITOR}; keryx types nothing into it. The session joins once it is closed.")
    end

    def indented(lines) = lines.map { "  #{it}" }.join("\n")
  end
end
