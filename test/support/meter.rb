# frozen_string_literal: true

module MeterHelpers
  SOCKET = '/h.sock'
  FIXTURES = File.expand_path('../fixtures/context', __dir__)
  DOT = [0xB7].pack('U')
  ARROW = [0x2192].pack('U')
  SLUG = '-work-repo-v1-0'

  class Lookout
    attr_accessor :verdict

    def initialize = @verdict = :there

    def in_pane(_occupant) = Keryx::Lookout::Sighting.new(verdict:, agent: nil, detail: nil)
  end

  def herdr = @herdr ||= FakeHerdr.new

  def lookout = @lookout ||= Lookout.new

  def env = @env ||= { 'HOME' => tmp('home') }

  def meter = Keryx::Meter.new(env:, herdr:, lookout:)

  def read(**occupant) = meter.read(build_occupant(cwd: '/work/repo.v1_0', **occupant))

  def fixture(name) = File.read(File.join(FIXTURES, name))

  def put(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def transcript(content = fixture('claude-transcript.jsonl'), slug: SLUG, id: 'session-1', home: nil)
    put(File.join(home || tmp('home', '.claude'), 'projects', slug, "#{id}.jsonl"), content)
  end

  def rollout(content = fixture('codex-rollout.jsonl'), day: '2026/10/22', thread: 'thread-1', home: nil)
    put(File.join(home || tmp('home', '.codex'), 'sessions', day, "rollout-2026-10-22T17-00-00-#{thread}.jsonl"),
        content)
  end

  def assistant(usage, session = 'session-1')
    JSON.generate('type' => 'assistant', 'isSidechain' => false, 'sessionId' => session,
                  'message' => { 'role' => 'assistant', 'content' => [], 'usage' => usage })
  end

  def meta(thread = 'thread-1') = JSON.generate('type' => 'session_meta', 'payload' => { 'id' => thread })

  def link(target, path)
    FileUtils.mkdir_p(File.dirname(path))
    File.symlink(target, path)
    path
  end

  def cursor(footer, verdict: :there)
    lookout.verdict = verdict
    herdr.footers[[SOCKET, 'w1:p2']] = footer
    read(harness: 'cursor', session_id: 'conversation-1', herdr_socket: SOCKET, herdr_pane: 'w1:p2')
  end

  def token_count(usage)
    JSON.generate('type' => 'event_msg', 'payload' => { 'type' => 'token_count',
                                                        'info' => { 'last_token_usage' => usage,
                                                                    'model_context_window' => 'big' } })
  end
end
