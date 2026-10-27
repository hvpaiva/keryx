# frozen_string_literal: true

require 'fileutils'
require 'json'

# Stub checkers for the message check, written as root would leave them, and readers for what they recorded. Each
# machine's checker appends every envelope it reads to a record of its own, an absolute path baked into the script,
# since the checker runs in / with an empty environment.
module MessageCheckHelpers
  REASON = 'subject line missing'

  # A check that runs CHECKER, the trust walk refusing a folder or file the group can write whatever the umask.
  def check_with(checker, host: 'athena', timeout: 5)
    [real_tmp('etc'), real_tmp('etc', host)].each do |folder|
      FileUtils.mkdir_p(folder)
      File.chmod(0o755, folder)
    end
    File.write(check_path(host), "command = #{checker}\ntimeout = #{timeout}\n")
    File.chmod(0o644, check_path(host))
  end

  def accepting(host = 'athena') = check_with(checker(host), host:)

  def refusing(host = 'athena', reason: REASON) = check_with(checker(host, status: 1, reason:), host:)

  # The checker of HOST, which records the envelope and exits STATUS with REASON on stderr. It sits in the test's own
  # folder, which only the test user can write.
  def checker(host, status: 0, reason: nil)
    path = real_tmp("#{host}-checker")
    lines = ['#!/bin/sh', "cat >> #{record(host)}"]
    lines += ["cat >&2 <<'REASON'", reason, 'REASON'] if reason
    File.write(path, [*lines, "exit #{status}", ''].join("\n"))
    File.chmod(0o755, path)
    path
  end

  def record(host = 'athena') = tmp("#{host}-record")

  # The envelopes the checker of HOST read, oldest first; none when it never ran.
  def envelopes(host = 'athena')
    File.exist?(record(host)) ? File.readlines(record(host)).map { JSON.parse(it) } : []
  end

  def zeus = Keryx::Store.new(tmp('zeus'))

  # The message of ID as the mailbox of NAME holds it, as the JSON keryx stored.
  def held(name, id, box: store)
    stored = box.stored(name).find { it.message.id == id }
    stored && JSON.parse(stored.message.to_json)
  end

  def refused_text(reason = REASON) = "error: the check refused the message:\n#{reason}\n"

  def not_forwarded = JSON.parse(keryx('status', '-o', 'json').out)['not_forwarded']

  def open_requests = JSON.parse(keryx('status', '-o', 'json').out)['open_requests'].map { it['id'] }

  # The one check this command ran on athena, for a message the mailbox of RECIPIENT now holds field for field.
  def assert_checked(run, command, recipient)
    assert_equal [0, ''], [run.status, run.err]
    assert_equal 1, envelopes.size
    envelope = envelopes.first

    assert_equal [1, 'send', 'athena', command], envelope.values_at('check', 'event', 'host', 'command')
    assert_equal held(recipient, envelope.dig('message', 'id')), envelope['message']
  end

  # Refused before anything was written, queued or rung.
  def assert_refused(run, reason = REASON)
    assert_equal [1, '', refused_text(reason)], [run.status, run.out, run.err]
    assert_empty sockets.posts
    assert_empty store.outbox.outgoing
  end

  def must(run)
    raise "keryx failed: #{run.err}" unless run.status.zero?

    run
  end
end
