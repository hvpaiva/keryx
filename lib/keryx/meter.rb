# frozen_string_literal: true

require 'json'
require_relative 'context'
require_relative 'herdr'

module Keryx
  # Reads the context a session uses from the usage its harness records, and nothing else of the conversation.
  class Meter
    SESSION_ID = /\A[A-Za-z0-9][A-Za-z0-9-]{0,127}\z/
    BLOCK_BYTES = 64 * 1024
    LIMIT_BYTES = 8 * 1024 * 1024
    CLAUDE_USAGE = %w[input_tokens cache_read_input_tokens cache_creation_input_tokens].freeze
    # Cursor's footer names the model's window, as in "Opus 300K High", then a middle dot and the share in use, and
    # only its mode, set apart by a wider gap, may follow on the same line.
    CURSOR_FOOTER = /(?<!\S)(?<window>\d+)(?<unit>[KM])(?!\S).*\u00B7\s*(?<share>\d+(?:\.\d+)?)%(?:\s{2,}\S.*)?\z/
    UNITS = { 'K' => 1000, 'M' => 1_000_000 }.freeze
    NO_COUNT = :no_count

    # A path a Claude Code hook names counts only where Claude Code keeps that session's transcript, unlinked.
    def self.transcript(path, id)
      file = session_file(id)
      return unless file && path.is_a?(String) && File.absolute_path?(path)

      real = File.realpath(path)
      real if [path, real].all? { File.basename(it) == file } && File.basename(File.dirname(real, 2)) == 'projects'
    rescue SystemCallError
      nil
    end

    def self.session_file(id)
      "#{id}.jsonl" if id.is_a?(String) && SESSION_ID.match?(id)
    end
    private_class_method :session_file

    def initialize(env:, herdr:, lookout:)
      @env = env
      @herdr = herdr
      @lookout = lookout
    end

    # A figure that cannot be read is nil, so measuring never fails the command that asked.
    def read(occupant)
      case occupant&.harness
      when 'claude' then claude(occupant)
      when 'codex' then codex(occupant)
      when 'cursor' then cursor(occupant)
      end
    rescue StandardError
      nil
    end

    private

    def claude(occupant)
      id = session_id(occupant) or return
      path = Meter.transcript(occupant.transcript, id) || claude_transcript(id, occupant.cwd) or return
      last(path) { claude_usage(it) }
    end

    # Claude Code keeps a transcript per session under a folder named after its directory, and shortens long names.
    def claude_transcript(id, cwd)
      projects = File.join(home('CLAUDE_CONFIG_DIR', '.claude', cwd), 'projects')
      direct = File.join(projects, cwd.gsub(/[^A-Za-z0-9]/, '-'), "#{id}.jsonl")
      File.file?(direct) ? direct : only(projects, "*/#{id}.jsonl")
    end

    def claude_usage(line)
      entry = JSON.parse(line) if line.include?('"usage"')
      return unless field(entry, 'type') == 'assistant' && field(entry, 'isSidechain') != true

      used = claude_sum(field(entry, 'message', 'usage'))
      Context.new(used:, window: nil) if used
    end

    def claude_sum(usage)
      counts = usage.values_at(*CLAUDE_USAGE).compact if usage.is_a?(Hash)
      counts.sum if counts&.all? { it.is_a?(Integer) && !it.negative? } && counts.sum.positive?
    end

    def codex(occupant)
      id = session_id(occupant) or return
      path = only(File.join(home('CODEX_HOME', '.codex', occupant.cwd), 'sessions'), "*/*/*/rollout-*-#{id}.jsonl")
      found = path && last(path) { codex_usage(it) }
      found if found.is_a?(Context)
    end

    # The last count stands even when it is not positive; only an event that carries none is passed over.
    def codex_usage(line)
      event = JSON.parse(line) if line.include?('"token_count"')
      return unless field(event, 'type') == 'event_msg' && field(event, 'payload', 'type') == 'token_count'

      info = field(event, 'payload', 'info')
      used = field(info, 'last_token_usage', 'input_tokens')
      return unless used.is_a?(Integer)
      return NO_COUNT unless used.positive?

      window = field(info, 'model_context_window')
      Context.new(used:, window: Context.count?(window) ? window : nil)
    end

    def cursor(occupant)
      return unless @lookout.in_pane(occupant).there?

      footer = @herdr.footer(occupant.herdr_socket, occupant.herdr_pane) or return
      lines = String.new(footer, encoding: Encoding::UTF_8).scrub.lines.last(Herdr::FOOTER_LINES).map(&:strip)
      lines.reverse_each.lazy.filter_map { footer_context(it) }.first
    end

    # The directory Cursor shows under the footer may wrap, and the conversation never reaches these last lines.
    def footer_context(line)
      match = CURSOR_FOOTER.match(line) or return
      window = Integer(match[:window], 10) * UNITS.fetch(match[:unit])
      used = (match[:share].to_r * window / 100).round
      Context.new(used:, window:) if used.positive?
    end

    def session_id(occupant)
      id = occupant.session_id
      id if id.is_a?(String) && SESSION_ID.match?(id)
    end

    def field(data, *keys) = keys.reduce(data) { |value, key| value[key] if value.is_a?(Hash) }

    # A variable that is set wins, even when relative; the session resolved it against its own directory.
    def home(variable, folder, cwd)
      value = @env[variable].to_s
      return File.expand_path(value, cwd) unless value.empty?

      File.join(@env['HOME'].to_s.empty? ? Dir.home : @env['HOME'], folder)
    end

    def only(base, pattern)
      found = Dir.glob(pattern, base:)
      File.join(base, found.first) if found.one?
    end

    def last(path, &reader)
      File.open(path, File::RDONLY | File::NONBLOCK) { |file| backwards(file, reader) if file.stat.file? }
    end

    # From the end, so a long transcript costs only its last lines, and never further back than LIMIT_BYTES. A line is
    # joined once it is whole, so one longer than a block costs no more than its own bytes.
    def backwards(file, reader)
      carry = []
      position = file.size
      floor = [position - LIMIT_BYTES, 0].max
      while position > floor
        size = [BLOCK_BYTES, position - floor].min
        position -= size
        file.seek(position)
        parts = file.read(size).split("\n", -1)
        carry.unshift(parts.pop)
        next if parts.empty? && position.positive?

        lines = [*(position.zero? ? parts : parts.drop(1)), carry.join]
        carry = [parts.first]
        found = lines.reverse_each.lazy.filter_map { taken(it, reader) }.first
        return found if found
      end
    end

    def taken(line, reader)
      reader.call(line.force_encoding(Encoding::UTF_8))
    rescue StandardError
      nil
    end
  end
end
