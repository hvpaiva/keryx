# frozen_string_literal: true

require 'fileutils'
require_relative 'error'

module Keryx
  # How keryx reads and writes the store through no symbolic link, from below its root, which @root names, down to each
  # file. The root and the folders above it may be links, as a home folder on another disk is. A link found on a read
  # is reported in @problems, or refused, the way a file that is not regular is; a link found on a write is refused.
  module Links
    # A read or a write refused at a symbolic link, which it names.
    class Linked < Error
      attr_reader :link

      def initialize(link)
        @link = link
        super("#{link} is a symbolic link")
      end
    end

    private

    # A file of the store, or nil when it is not a regular file, as a link in its place is not.
    def read_stored(path)
      refuse_link(File.dirname(path))
      read_regular(path, File::NOFOLLOW)
    end

    # keryx neither reads nor writes through a folder that a symbolic link stands for.
    def refuse_link(path)
      link = first_link(path)
      raise Linked, link if link
    end

    def make_dirs(base, dirs)
      dirs.map { File.join(base, it) }.each do |dir|
        refuse_link(dir)
        FileUtils.mkdir_p(dir, mode: Files::DIR_MODE)
      end
    end

    # Every file keryx writes is first made here, under a name nothing holds yet, so a link there is refused too.
    def create_file(path, &)
      refuse_link(File.dirname(path))
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, Files::FILE_MODE, &)
    end

    # A lock file, which keryx creates when missing, opens through no symbolic link in its place.
    def open_lock(path, &)
      File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, Files::FILE_MODE, &)
    rescue Errno::ELOOP
      raise Error, "#{path} is a symbolic link" if File.symlink?(path)

      raise
    end

    # The problem a record keryx cannot read makes. A damaged one is written again; one behind a link never is, since
    # writes refuse the link too, so the link is skipped as a folder is.
    def ignored(error)
      return "skipped #{error.link}: a symbolic link" if error.is_a?(Linked)

      "#{error.message}; it is ignored until keryx writes it again"
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
