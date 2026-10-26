# frozen_string_literal: true

require_relative 'error'
require_relative 'links'

module Keryx
  # The file at the root of the store whose mtime tells a reader that the store changed, with one stat and no read.
  # Every write notes its change once made, and the process moves the mtime once for all it noted, before it sleeps
  # and when its command ends, so a reader that saw the mtime move and then runs a command sees each change before it.
  class Changes
    include Links

    FILE = 'changed'
    # The least the mtime moves, so that two changes in one tick of the clock, or after the clock stepped back, still
    # differ for a reader that keeps only milliseconds, as a float of seconds or a JavaScript Date does.
    STEP = Rational(1, 1000)
    # A filesystem that keeps whole seconds, or even ones, rounds STEP away; the mtime then moves by these instead.
    COARSE_STEPS = [1, 2].freeze

    attr_reader :path

    def initialize(root, clock: -> { Time.now.utc })
      @root = root
      @path = File.join(root, FILE)
      @clock = clock
      @pending = false
    end

    def note = @pending = true

    def pending? = @pending

    # Moves the mtime past every time it had, once for every change noted since the last signal, and makes the file
    # when it is missing. Changes whose signal failed stay noted, for the next one to signal.
    def signal
      return unless @pending

      refuse_link(path)
      open_lock(path) do |file|
        raise Error, "#{path} is not a regular file" unless file.stat.file?

        file.flock(File::LOCK_EX)
        advance(file)
      end
      @pending = false
    end

    private

    # Under the lock no other process moves the mtime between the read and the write, so it only ever moves forward.
    def advance(file)
      before = file.stat.mtime
      moved = [STEP, *COARSE_STEPS].find do |step|
        stamp([@clock.call, before + step].max)
        file.stat.mtime > before
      end
      raise Error, "#{path} kept its mtime, moved by up to #{COARSE_STEPS.last} seconds" unless moved
    end

    # lutime never follows a link put in place of the file since it was opened.
    def stamp(time) = File.lutime(time, time, path)
  end
end
