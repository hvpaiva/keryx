# frozen_string_literal: true

require_relative 'error'

module Keryx
  # How keryx reads the store through no symbolic link, from below its root, which @root names, down to each file. The
  # root and the folders above it may be links, as a home folder on another disk is. A link found is reported in
  # @problems, or refused, the way a file that is not regular is.
  module Links
    private

    # A file of the store, or nil when it is not a regular file, as a link in its place is not.
    def read_stored(path)
      link = first_link(File.dirname(path))
      raise Error, "#{link} is a symbolic link" if link

      read_regular(path, File::NOFOLLOW)
    end

    def stored_file?(path)
      !linked?(path) && File.lstat(path).file?
    rescue Errno::ENOENT, Errno::ENOTDIR
      false
    end

    def stored_folder?(path) = !linked?(path) && File.directory?(path)

    # Whether a symbolic link stands for PATH or for a folder on its way, which is then reported as a problem.
    def linked?(path)
      link = first_link(path) or return false
      @problems << "skipped #{link}: a symbolic link"
      true
    end

    # The first entry from below the root down to PATH, PATH included, that is a symbolic link, or nil.
    def first_link(path)
      prefix = File.join(@root, '')
      raise ArgumentError, "#{path} is outside the store #{@root}" unless path.start_with?(prefix)

      parts = path.delete_prefix(prefix).split('/')
      parts.each_index.lazy.map { File.join(@root, *parts[..it]) }.find { File.lstat(it).symlink? }
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end
  end
end
