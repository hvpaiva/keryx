# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module TempDir
  # UNIX socket paths are limited to about 100 bytes, and macOS's Dir.tmpdir is too deep for them.
  def setup
    super
    @tmp = Dir.mktmpdir('keryx-', File.directory?('/tmp') ? '/tmp' : Dir.tmpdir)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
    super
  end

  def tmp(*parts) = File.join(@tmp, *parts)
end

module Factory
  NOW = Time.utc(2026, 10, 22, 17, 0, 0)

  def build_message(to:, from: 'orq@athena', kind: 'message', body: 'hello', id: Keryx::Ulid.generate,
                    in_reply_to: nil, thread: nil, due_at: nil, created_at: NOW)
    Keryx::Message.new(id:, kind:, from:, to:, thread: thread || id, in_reply_to:, created_at:, due_at:, body:)
  end

  def build_occupant(**overrides)
    Keryx::Occupant.new(harness: 'claude', session_id: 'session-1', pid: nil, started: nil, claude_socket: nil,
                        herdr_socket: nil, herdr_pane: nil, cwd: '/work', joined_at: NOW, **overrides)
  end
end
