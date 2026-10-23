# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'context'
require_relative 'herdr'

module Keryx
  # Reads the context a session uses from the usage its harness records, and nothing else of the conversation, and when
  # the harness last wrote the session's own record.
  class Meter
    SESSION_ID = /\A[A-Za-z0-9][A-Za-z0-9-]{0,127}\z/
    BLOCK_BYTES = 64 * 1024
    LIMIT_BYTES = 8 * 1024 * 1024
    HEAD_BYTES = 1024 * 1024
    OPEN = File::RDONLY | File::NONBLOCK | File::NOFOLLOW
    CLAUDE_USAGE = %w[input_tokens cache_read_input_tokens cache_creation_input_tokens].freeze
    CLAUDE_LINE = ['"type":"assistant"', '"usage"'].freeze
    CODEX_LINE = '"type":"token_count"'
    CODEX_HEAD = '"type":"session_meta"'
    # Cursor's footer: the model's name, its window and labels, as in "Opus 5.5 300K Extra High", then after middle
    # dots more labels, the share in use and labels such as "1 file edited"; only its mode, set apart by a wider gap,
    # may follow on the line.
    CURSOR_FOOTER = Regexp.new('\A[A-Za-z][\w.-]*(?: [\w.-]+)*? (?<window>\d+)(?<unit>[KM])(?: [A-Za-z][\w-]*)*' \
                               '(?:(?: \u00B7 [A-Za-z][\w-]*(?: [A-Za-z][\w-]*)*)* \u00B7 (?<share>\d+(?:\.\d+)?)%' \
                               '(?: \u00B7 [\w-]+(?: [\w-]+)*)*)?(?: {2,}\S.*)?\z')
    UNITS = { 'K' => 1000, 'M' => 1_000_000 }.freeze
    NO_COUNT = :no_count
    CURSOR_STORE = %w[store.db store.db-wal].freeze

    # A transcript a Claude Code hook names counts only as that session's file in a folder under a projects
    # directory, with no link on the way. Anything else, whatever it holds, is no transcript.
    def self.transcript(path, id)
      return unless placed?(path, session_file(id))

      path if [path, File.dirname(path), File.dirname(path, 2)].none? { File.lstat(it).symlink? }
    rescue StandardError
      nil
    end

    def self.placed?(path, file)
      file && path.is_a?(String) && File.absolute_path?(path) && File.expand_path(path) == path &&
        File.basename(path) == file && File.basename(File.dirname(path, 2)) == 'projects'
    end

    def self.session_file(id)
      "#{id}.jsonl" if id.is_a?(String) && SESSION_ID.match?(id)
    end
    private_class_method :placed?, :session_file

    def initialize(env:, herdr:, lookout:)
      @env = env
      @herdr = herdr
      @lookout = lookout
      @rollouts = {}
      @paths = {}
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

    # When the harness last wrote the file it keeps for the session, which says nothing of what it wrote; nil when that
    # cannot be told, so it never fails the command that asked either.
    def activity(occupant)
      case occupant&.harness
      when 'claude' then written(claude_path(occupant))
      when 'codex' then written(codex_path(occupant))
      when 'cursor' then cursor_activity(occupant)
      end
    rescue StandardError
      nil
    end

    # Only the occupant's own transcript, in the projects directory keryx itself would look in.
    def transcript(path, occupant)
      found = Meter.transcript(path, occupant.session_id) or return
      found if File.dirname(found, 2) == File.join(home('CLAUDE_CONFIG_DIR', '.claude', occupant.cwd), 'projects')
    rescue StandardError
      nil
    end

    private

    def claude(occupant)
      id = session_id(occupant) or return
      path = claude_path(occupant) or return
      last(path) { claude_usage(it, id) }
    end

    def claude_path(occupant)
      id = session_id(occupant) or return
      remembered([:claude, occupant]) do
        transcript(occupant.transcript, occupant) || claude_transcript(id, occupant.cwd)
      end
    end

    # Claude Code keeps a transcript per session under a folder named after its directory, and shortens long names.
    def claude_transcript(id, cwd)
      root = home('CLAUDE_CONFIG_DIR', '.claude', cwd)
      direct = File.join('projects', cwd.gsub(/[^A-Za-z0-9]/, '-'), "#{id}.jsonl")
      found = File.exist?(File.join(root, direct)) ? direct : only(Dir.glob("projects/*/#{id}.jsonl", base: root))
      found && unlinked(root, found)
    end

    def claude_usage(line, id)
      entry = JSON.parse(line) if CLAUDE_LINE.all? { line.include?(it) }
      return unless field(entry, 'type') == 'assistant' && field(entry, 'sessionId') == id
      return if field(entry, 'isSidechain') == true

      used = claude_sum(field(entry, 'message', 'usage'))
      Context.new(used:, window: nil) if used
    end

    def claude_sum(usage)
      counts = usage.values_at(*CLAUDE_USAGE).compact if usage.is_a?(Hash)
      counts.sum if counts&.all? { it.is_a?(Integer) && !it.negative? } && Context.count?(counts.sum)
    end

    def codex(occupant)
      path = codex_path(occupant) or return
      count = last(path) { codex_usage(it) }
      count if count.is_a?(Context)
    end

    def codex_path(occupant)
      id = session_id(occupant) or return
      remembered([:codex, occupant]) do
        root = home('CODEX_HOME', '.codex', occupant.cwd)
        found = only(rollouts(root).select { it.end_with?("-#{id}.jsonl") })
        path = found && unlinked(root, found)
        path if path && thread?(path, id)
      end
    end

    # Cursor keeps each conversation in a folder named after the MD5 of the directory it runs in, a layout of its own
    # that it does not document. Only the time its store was last written is read, never what it holds.
    def cursor_activity(occupant)
      id = session_id(occupant) or return
      root = File.join(user_home, '.cursor')
      folder = File.join('chats', Digest::MD5.hexdigest(occupant.cwd), id)
      CURSOR_STORE.filter_map { store_written(root, File.join(folder, it)) }.max
    end

    def store_written(root, relative)
      written(unlinked(root, relative))
    rescue SystemCallError
      nil
    end

    # One listing per meter, which a command or a courier round makes afresh, since a long Codex history holds tens
    # of thousands of rollouts.
    def rollouts(root) = @rollouts[root] ||= Dir.glob('sessions/*/*/*/rollout-*.jsonl', base: root)

    # A rollout opens with its thread's own id, so the file name alone never says whose figure it holds.
    def thread?(path, id)
      head = open_regular(path) { it.gets("\n", HEAD_BYTES) }
      meta = JSON.parse(head) if head&.include?(CODEX_HEAD)
      field(meta, 'type') == 'session_meta' && field(meta, 'payload', 'id') == id
    end

    # The last count stands even when it is not positive; only an event that carries none is passed over.
    def codex_usage(line)
      event = JSON.parse(line) if line.include?(CODEX_LINE)
      return unless field(event, 'type') == 'event_msg' && field(event, 'payload', 'type') == 'token_count'

      info = field(event, 'payload', 'info')
      used = field(info, 'last_token_usage', 'input_tokens')
      return unless used.is_a?(Integer)
      return NO_COUNT unless Context.count?(used)

      window = field(info, 'model_context_window')
      Context.new(used:, window: Context.count?(window) ? window : nil)
    end

    # The footer sits above the directory Cursor shows under it, which may wrap, and the conversation never reaches
    # these last lines. A footer that shows no share is no figure; no other line stands in for it.
    # Once the footer gives a figure the pane is looked at again, as another conversation may have taken it meanwhile.
    def cursor(occupant)
      first = @lookout.in_pane(occupant)
      return unless first.there?

      footer = @herdr.footer(occupant.herdr_socket, occupant.herdr_pane) or return
      lines = String.new(footer, encoding: Encoding::UTF_8).scrub.lines.last(Herdr::FOOTER_LINES).map(&:strip)
      figure = footer_context(lines.lazy.filter_map { CURSOR_FOOTER.match(it) }.first)
      figure if figure && same_conversation?(first, @lookout.in_pane(occupant))
    end

    # Without a conversation the process stands in for it, and the process may have moved on to another one, so a
    # conversation the first look named is the one the second look has to name.
    def same_conversation?(first, again)
      named = first.agent&.session
      again.there? && (named.nil? || again.agent.session == named)
    end

    def footer_context(match)
      return unless match&.[](:share)

      window = Integer(match[:window], 10) * UNITS.fetch(match[:unit])
      used = (match[:share].to_r * window / 100).round
      Context.new(used:, window:) if Context.count?(used)
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

      File.expand_path(folder, user_home)
    end

    def user_home = @env['HOME'].to_s.empty? ? Dir.home : @env['HOME']

    # A path found once stands for the meter's life, which is one command or one courier round.
    def remembered(key) = @paths.key?(key) ? @paths[key] : (@paths[key] = yield)

    def only(found) = found.one? ? found.first : nil

    # No link from the root keryx derives down to the file, so the path names the file it seems to and no other.
    def unlinked(root, relative)
      parts = relative.split('/')
      steps = parts.each_index.map { File.join(root, *parts[..it]) }
      steps.last if steps.none? { File.lstat(it).symlink? }
    end

    def open_regular(path, &) = File.open(path, OPEN) { |file| yield file if file.stat.file? }

    def written(path) = path && open_regular(path, &:mtime)

    def last(path, &reader) = open_regular(path) { backwards(it, reader) }

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
