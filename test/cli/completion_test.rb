# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'rbconfig'

class CompletionTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def complete(*words, env: {}) = keryx('__complete', *words, env:).out.lines(chomp: true)

  def test_the_scripts_call_back_into_keryx
    assert_match(/complete -o default -F _keryx keryx/, keryx('completion', 'bash').out)
    assert_match(/\A#compdef keryx\n/, keryx('completion', 'zsh').out)
    assert_match(/complete -c keryx -f -a '\(__keryx_complete\)'/, keryx('completion', 'fish').out)
    assert_equal 2, keryx('completion', 'tcsh').status
  end

  def test_commands_complete_by_prefix_and_hide_the_endpoint
    assert_includes complete(''), 'join'
    refute_includes complete(''), '__complete'
    assert_equal %w[read reply ring], complete('r')
  end

  def test_addresses_complete_where_an_address_goes
    join_claude('orq', 111)
    join_claude('rev-1', 222)

    assert_equal %w[rev-1], complete('send', 'r')
    assert_equal %w[orq rev-1], complete('--as', '')
    assert_equal %w[orq rev-1], complete('ring', 'orq', '')
  end

  def test_message_ids_complete_for_read_reply_and_wait
    orq = join_claude('orq', 111)
    rev = join_claude('rev-1', 222)
    keryx('ask', 'rev-1', 'Review it', env: orq)
    id = last_id(rev)

    assert_equal [id], complete('read', '', env: rev)
    assert_equal [id], complete('reply', id[0, 4].downcase, env: rev)
    assert_equal [id], complete('wait', '', env: orq)
  end

  def test_ids_complete_from_the_mailbox_named_by_as
    join_claude('rev-1', 222)
    keryx('send', 'rev-1', 'for rev-1')
    keryx('send', 'person', 'for person')
    theirs = JSON.parse(keryx('--as', 'rev-1', 'inbox', '-o', 'json').out).map { it['id'] }

    assert_equal theirs, complete('--as', 'rev-1', 'read', '')
    assert_equal theirs, complete('read', '--as=rev-1', '')
  end

  def test_flags_and_values_complete
    assert_includes complete('ask', '--'), '--within'
    assert_includes complete('ask', '--'), '--as'
    assert_equal %w[table json], complete('inbox', '-o', '')
    assert_equal %w[bash zsh fish], complete('completion', '')
  end

  def test_completion_never_fails
    alive << 999
    result = keryx('__complete', 'read', '', env: claude(999))

    assert_equal 0, result.status
    assert_empty result.out
    assert_empty result.err
  end

  def test_the_bash_script_completes_in_a_real_bash
    skip 'bash is not installed' unless system('bash', '-c', 'true')

    bin = tmp('bin')
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, 'keryx'), "#!/bin/sh\nexec #{RbConfig.ruby} -I#{lib} #{exe} \"$@\"\n")
    File.chmod(0o755, File.join(bin, 'keryx'))
    script = keryx('completion', 'bash').out
    probe = "#{script}\nCOMP_WORDS=(keryx sta); COMP_CWORD=1; _keryx; printf '%s\\n' \"${COMPREPLY[@]}\""
    out, status = Open3.capture2e({ 'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'KERYX_HOME' => tmp('state') },
                                  'bash', '--norc', '-c', probe)

    assert_predicate status, :success?, out
    assert_equal "status\n", out
  end

  private

  def lib = File.expand_path('../../lib', __dir__)

  def exe = File.expand_path('../../exe/keryx', __dir__)
end
