# frozen_string_literal: true

require 'test_helper'

# purge removes a link in an address's folder without following it, and refuses a folder that is a link.
class PurgeLinksTest < Minitest::Test
  include TempDir
  include Factory
  include CLIHelpers

  def setup
    super
    @orq = join_claude('orq.dev', 111)
    join_claude('rev-1.dev', 222)
    alive.delete(222)
    keryx('retire', 'rev-1.dev')
  end

  def box(*parts) = tmp('state', 'addresses', 'rev-1.dev', *parts)

  def purged
    result = keryx('purge', 'rev-1.dev', env: @orq)
    raise "purge failed: #{result.err}" unless result.status.zero?
  end

  # Each entry under ROOT, as lstat sees it: a link by its target, a file by its content, a folder by its name alone.
  def tree(root)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: root).sort.filter_map do |path|
      [path, entry(File.join(root, path))] unless File.basename(path) == '.'
    end
  end

  def entry(path)
    stat = File.lstat(path)
    return [:link, File.readlink(path)] if stat.symlink?

    stat.file? ? File.binread(path) : :folder
  end

  # Outside the store, a file, a folder with a file, and a folder of read marks.
  def outside_folder
    root = tmp('outside')
    FileUtils.mkdir_p([File.join(root, 'folder'), File.join(root, 'marks')])
    File.write(File.join(root, 'file'), 'kept')
    File.write(File.join(root, 'folder', 'inner'), 'kept')
    File.write(File.join(root, 'marks', "#{'1' * 26}.json"), 'kept')
    root
  end

  def test_purge_removes_links_and_leaves_what_they_point_to
    outside = outside_folder
    File.symlink(File.join(outside, 'file'), box('mail', "#{'0' * 26}.json"))
    File.symlink(File.join(outside, 'folder'), box('receipts', 'linked'))
    Dir.rmdir(box('read'))
    File.symlink(File.join(outside, 'marks'), box('read'))
    FileUtils.rm_rf(box('tmp'))
    File.symlink(File.join(outside, 'file'), box('tmp'))
    before = tree(outside)
    purged

    assert_equal before, tree(outside)
    assert_equal %w[address.json retired.json], Dir.children(box).sort
  end

  # The store reads no address through a link, so the folder is no address at all.
  def test_purge_refuses_an_address_folder_linked_out_of_the_store
    FileUtils.mv(box, tmp('elsewhere'))
    File.symlink(tmp('elsewhere'), box)
    before = [tree(tmp('elsewhere')), tree(tmp('state'))]
    result = keryx('purge', 'rev-1.dev', env: @orq)

    assert_equal [1, "error: no address rev-1.dev@athena\n"], [result.status, result.err.lines.first]
    assert_includes result.err, "skipped #{box}: a symbolic link"
    assert_equal before, [tree(tmp('elsewhere')), tree(tmp('state'))]
  end

  def test_purge_prints_no_address_for_a_folder_linked_out_of_the_store
    FileUtils.mv(box, tmp('elsewhere'))
    File.symlink(tmp('elsewhere'), box)
    result = keryx('purge', 'rev-1.dev', '-o', 'json', env: @orq)

    assert_equal 1, result.status
    assert_equal({ 'schema' => 1, 'address' => 'rev-1.dev@athena', 'outcome' => 'refused', 'reason' => 'no_address',
                   'error' => 'no address rev-1.dev@athena' }, JSON.parse(result.out))
    assert_includes result.err, "skipped #{box}: a symbolic link"
  end
end
