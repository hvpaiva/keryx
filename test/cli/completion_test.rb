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
    assert_equal %w[retire read reply ring], complete('r')
  end

  def test_addresses_complete_where_an_address_goes
    join_claude('orq.dev', 111)
    join_claude('rev-1.dev', 222)

    assert_equal %w[rev-1.dev], complete('send', 'r')
    assert_equal %w[orq.dev rev-1.dev], complete('--as', '')
    assert_equal %w[orq.dev rev-1.dev], complete('ring', 'orq.dev', '')
  end

  def test_a_retired_address_does_not_complete
    join_claude('orq.dev', 111)
    join_claude('rev-1.dev', 222)
    alive.delete(222)
    keryx('retire', 'rev-1.dev')

    assert_empty complete('send', 'r')
    assert_equal %w[orq.dev person.local], complete('--as', '')
    assert_equal %w[orq.dev person.local], complete('retire', '')
  end

  def test_message_ids_complete_for_read_reply_and_wait
    orq = join_claude('orq.dev', 111)
    rev = join_claude('rev-1.dev', 222)
    keryx('ask', 'rev-1.dev', 'Review it', env: orq)
    id = last_id(rev)

    assert_equal [id], complete('read', '', env: rev)
    assert_equal [id], complete('reply', id[0, 4].downcase, env: rev)
    assert_equal [id], complete('wait', '', env: orq)
  end

  def test_re_completes_the_open_requests_in_this_mailbox_and_no_address_after_it
    orq = join_claude('orq.dev', 111)
    rev = join_claude('rev-1.dev', 222)
    ids = Array.new(2) do
      keryx('ask', 'rev-1.dev', 'Review it', env: orq).out[/\((\w{26})\)/, 1].tap do
        clock.advance(1)
      end
    end
    keryx('reply', ids.last, 'Done', env: rev)
    keryx('send', 'rev-1.dev', 'heads-up', env: orq)

    assert_equal [ids.first], complete('send', '--re', '', env: rev)
    assert_empty complete('send', '--re', ids.first, '', env: rev)
    assert_empty complete('send', "--re=#{ids.first}", '', env: rev)
    assert_includes complete('send', '', env: rev), 'orq.dev'
  end

  def test_withdraw_completes_the_open_requests_sent_from_this_machine_under_any_name
    orq = join_claude('orq.dev', 111)
    join_claude('rev-1.dev', 222)
    ids = [{}, { 'KERYX_HOST' => 'lap-0042' }, {}].map do |host|
      keryx('ask', 'rev-1.dev', 'Review it', env: orq.merge(host)).out[/\((\w{26})\)/, 1].tap { clock.advance(1) }
    end
    keryx('withdraw', ids.last, env: orq)

    assert_equal ids.first(2), complete('withdraw', '', env: orq)
  end

  def test_ids_complete_from_the_mailbox_named_by_as
    join_claude('rev-1.dev', 222)
    keryx('send', 'rev-1.dev', 'for rev-1')
    keryx('send', 'person.local', 'for person')
    theirs = JSON.parse(keryx('--as', 'rev-1.dev', 'inbox', '-o', 'json').out).map { it['id'] }

    assert_equal theirs, complete('--as', 'rev-1.dev', 'read', '')
    assert_equal theirs, complete('read', '--as=rev-1', '')
  end

  def test_words_bash_splits_at_an_equals_sign_complete_as_one
    join_claude('rev-1.dev', 222)
    keryx('send', 'rev-1.dev', 'for rev-1')
    keryx('send', 'person.local', 'for person')
    theirs = JSON.parse(keryx('--as', 'rev-1.dev', 'inbox', '-o', 'json').out).map { it['id'] }

    assert_equal theirs, complete('--as', '=', 'rev-1.dev', 'read', '')
    assert_equal %w[person.local rev-1.dev], complete('--as', '=', '')
    assert_equal %w[json], complete('inbox', '--output', '=', 'j')
  end

  def test_flags_and_values_complete
    assert_includes complete('ask', '--'), '--within'
    assert_includes complete('ask', '--'), '--as'
    assert_equal %w[table json], complete('inbox', '-o', '')
    assert_equal %w[bash zsh fish], complete('completion', '')
  end

  def test_spawn_completes_harnesses_and_directions_and_nothing_for_the_harness
    assert_equal %w[claude codex cursor], complete('spawn', 'rev-1.dev', '--harness', '')
    assert_equal %w[right down], complete('spawn', '--split', '')
    assert_includes complete('spawn', '--'), '--harness'
    assert_empty complete('spawn', 'rev-1.dev', '--', '--')
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
