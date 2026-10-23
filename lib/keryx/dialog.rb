# frozen_string_literal: true

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

    # The dialog a read of the pane shows below the command herdr typed, as the lines spawn quotes, or nil when it
    # shows none. That command holds the first prompt, whose words could pass for a dialog.
    def self.excerpt(read, prompt)
      lines = below(read, prompt)
      block(lines).filter_map { quoted(it) }.last(LINES) if Bell.dialog?(lines.join("\n"))
    end

    def self.cramped?(read, prompt) = Bell.cramped?(below(read, prompt).join("\n"))

    # The lines after the one where the typed command ends, which the last letters and digits of the first prompt end.
    def self.below(read, prompt)
      lines = String.new(read.to_s, encoding: Encoding::UTF_8).scrub(Text::REPLACEMENT).lines(chomp: true)
      tail = letters(prompt).chars.last(TAIL).join
      pieces = lines.map { letters(it) }
      at = pieces.join.rindex(tail) unless tail.empty?
      return lines unless at

      seen = 0
      lines.drop(pieces.index { (seen += it.size) >= at + tail.size } + 1)
    end

    # From the last box top or rule that still has the dialog below it, else from the first line.
    def self.block(lines)
      borders = lines.each_index.select { border?(lines[it]) }
      start = borders.reverse.find { Bell.dialog?(lines.drop(it + 1).join("\n")) }
      start ? lines.drop(start + 1) : lines
    end

    def self.border?(line) = TOP.match?(line.lstrip) || RULE.match?(line.strip)

    def self.quoted(line)
      text = line.gsub(Bell::BOX_DRAWING, ' ').squeeze(' ').strip
      return if text.empty?

      text = Text.plain(text)
      text.size > WIDTH ? "#{text[0, WIDTH - 1]}#{CUT}" : text
    end

    def self.letters(text) = text.to_s.gsub(/[^[:alnum:]]/, '')
    private_class_method :below, :block, :border?, :quoted, :letters

    def initialize(herdr:, socket:, pane:, address:, director:, prompt:, notice:, post:)
      @herdr = herdr
      @socket = socket
      @pane = pane
      @address = address
      @director = director
      @prompt = prompt
      @notice = notice
      @post = post
      @shown = nil
      @quoted = nil
      @cramped = false
    end

    # What a poll found: :dialog when herdr or the screen says a dialog may show, :cramped when the screen is too narrow
    # to tell, or nil. A dialog is quoted once a read of the pane shows one, and until then each signal reads again.
    def signal(obstacle)
      @shown = obstacle
      return cramped if obstacle == :cramped
      return if obstacle.nil? || @quoted

      read = @herdr.visible(@socket, @pane) or return
      excerpt = Dialog.excerpt(read, @prompt)
      return quote(excerpt) if excerpt

      cramped if Dialog.cramped?(read, @prompt)
    end

    def late
      waiting = "#{@address} has not joined yet"
      if @quoted
        "#{waiting}: pane #{@pane} shows the dialog below, and the session joins by itself once it is answered; " \
          "keryx never answers one\n#{indented(again)}"
      elsif @shown == :cramped
        "#{waiting}: pane #{@pane} #{CRAMPED}; look at it, and the session joins by itself once any dialog is " \
          'answered'
      else
        "#{waiting}; look at pane #{@pane}"
      end
    end

    private

    # The deadline reads the pane again, since the dialog may have changed, such as from a folder trust to a permission
    # question.
    def again = @herdr.visible(@socket, @pane)&.then { Dialog.excerpt(it, @prompt) } || @quoted

    def quote(excerpt)
      @quoted = excerpt
      text = indented(excerpt)
      @notice.call("Pane #{@pane} shows a dialog, and #{@address} joins once it is answered; keryx never answers " \
                   "one. Its text follows.\n#{text}")
      tell(text) if @director
    end

    def tell(text)
      @post.call(@director, "Pane #{@pane}, where spawn started #{@address}, stops at a dialog, and the session " \
                            'joins once it is answered; keryx never answers one. Its text follows.' \
                            "\n\n#{text}\n\nTake it to your human, and answer it with 'herdr pane send-keys' only " \
                            'on their word.')
    rescue Error, SystemCallError => e
      @notice.call("spawn could not tell #{@director} about the dialog in pane #{@pane}: #{e.message}.")
    end

    def cramped
      @shown = :cramped
      return if @cramped

      @cramped = true
      @notice.call("Pane #{@pane} #{CRAMPED}, such as a folder trust or permission question. Look at it there; " \
                   'keryx never answers one. The session joins once any dialog is answered.')
    end

    def indented(lines) = lines.map { "  #{it}" }.join("\n")
  end
end
