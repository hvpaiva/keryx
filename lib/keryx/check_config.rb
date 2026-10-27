# frozen_string_literal: true

require_relative 'error'

module Keryx
  # /etc/keryx/check, where root names the checker keryx runs before it writes a message. The file, the checker and
  # every folder above them must be root's and closed to others, so the file validated is the file read and the
  # checker validated is the one run. Any problem refuses, since the check fails closed.
  class CheckConfig
    # The file or its checker cannot be trusted or read, which refuses every message that needs the check.
    class Broken < Error; end

    PATH = '/etc/keryx/check'
    KEYS = %w[command timeout].freeze
    TIMEOUTS = (1..30)
    DEFAULT_TIMEOUT = 5
    ROOT = ->(stat) { stat.uid.zero? }
    OPEN = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
    # Ruby, like execvp, hands a file the kernel cannot execute to /bin/sh, so a checker must start as a script or a
    # binary does: #!, or the magic of ELF or of Mach-O, thin in either byte order or universal.
    HEADERS = ['#!', "\x7FELF", "\xFE\xED\xFA\xCE", "\xFE\xED\xFA\xCF", "\xCE\xFA\xED\xFE", "\xCF\xFA\xED\xFE",
               "\xCA\xFE\xBA\xBE"].map(&:b).freeze
    Setup = Data.define(:command, :timeout)

    attr_reader :path

    def initialize(path: PATH, trusted: ROOT)
      @path = path
      @trusted = trusted
    end

    # The checker and its timeout, or nil when there is no file.
    def setup
      text = read or return
      settings = parse(text)
      command, line = settings.fetch('command') { raise Broken, "#{@path} names no command" }
      raise Broken, "#{@path}:#{line}: command must be an absolute path, not #{command.inspect}" unless
        command.start_with?('/')

      vet_checker(command)
      Setup.new(command:, timeout: timeout(*settings['timeout']))
    end

    private

    # Every test runs on the stat of the open descriptor, so nothing changes between the test and the read. Only a file
    # that is not there means no check, so a folder that vanishes during the walk refuses.
    def read
      file = opened or return
      vet(@path, file.stat)
      walk(@path)
      file.read
    rescue SystemCallError => e
      raise Broken, "cannot read #{@path}: #{e.message.sub(/ @ .*/, '')}"
    ensure
      file&.close
    end

    def opened
      File.open(@path, OPEN)
    rescue Errno::ENOENT
      nil
    rescue Errno::ELOOP
      raise Broken, "#{@path} is a symbolic link; keryx honors only a regular file"
    end

    def vet(name, stat)
      raise Broken, "#{name} is not a regular file" unless stat.file?
      raise Broken, "#{name} is not owned by root" unless @trusted.call(stat)
      raise Broken, "#{name} is writable by group or others" if stat.mode.anybits?(0o022)
    end

    # A folder others can write lets them rename another file over the one in it, unless it is sticky, where only the
    # owner of an entry, of the folder or root moves it. A link on the way is refused, so the path is the real one.
    def walk(path)
      folder = File.dirname(path)
      loop do
        vet_folder(folder, File.lstat(folder))
        break if folder == '/'

        folder = File.dirname(folder)
      end
    end

    def vet_folder(folder, stat)
      raise Broken, "#{folder} is a symbolic link; name the file under its real path" if stat.symlink?
      raise Broken, "#{folder} is not a directory" unless stat.directory?
      raise Broken, "#{folder} is not owned by root, so the file in it could be replaced" unless @trusted.call(stat)
      return if stat.sticky? || stat.mode.nobits?(0o022)

      raise Broken, "#{folder} is writable by group or others, so the file in it could be replaced"
    end

    # exec takes a path, so the checker is tested by lstat, and the folders above it keep it the file run. Its header is
    # read too, so a checker keryx cannot read is refused even where the kernel could run it.
    def vet_checker(command)
      name = "the checker #{command}"
      stat = File.lstat(command)
      raise Broken, "#{name} is a symbolic link; name the file itself" if stat.symlink?

      vet(name, stat)
      walk(command)
      raise Broken, "#{name} is not executable" unless File.executable?(command)
      raise Broken, "#{name} starts with neither #! nor an ELF or Mach-O header" unless runnable?(command)
    rescue Errno::ENOENT
      raise Broken, "#{name} does not exist"
    rescue SystemCallError, ArgumentError => e
      raise Broken, "cannot read #{name}: #{e.message.sub(/ @ .*/, '')}"
    end

    def runnable?(command)
      header = File.open(command, OPEN) { it.read(HEADERS.map(&:bytesize).max) }.to_s
      HEADERS.any? { header.start_with?(it) }
    end

    # Each key by name, with its value and the line it is on.
    def parse(text)
      text = text.dup.force_encoding(Encoding::UTF_8)
      raise Broken, "#{@path}: not valid UTF-8" unless text.valid_encoding?

      text.each_line.with_index(1).each_with_object({}) do |(line, number), settings|
        raise Broken, "#{@path}:#{number}: holds a NUL byte" if line.include?("\0")

        pair = setting(line.strip, number) or next
        key, value = pair
        earlier = settings[key]
        raise Broken, "#{@path}:#{number}: #{key} is set again, after line #{earlier.last}" if earlier

        settings[key] = [value, number]
      end
    end

    def setting(line, number)
      return if line.empty? || line.start_with?('#')

      key, value = line.split('=', 2).map(&:strip)
      raise Broken, "#{@path}:#{number}: expected key = value" unless value
      raise Broken, "#{@path}:#{number}: unknown key #{key.inspect}" unless KEYS.include?(key)

      [key, value]
    end

    def timeout(value = nil, line = nil)
      return DEFAULT_TIMEOUT unless value

      seconds = Integer(value, 10) if value.match?(/\A\d+\z/)
      return seconds if TIMEOUTS.cover?(seconds)

      raise Broken, "#{@path}:#{line}: timeout must be a whole number of seconds from #{TIMEOUTS.min} to " \
                    "#{TIMEOUTS.max}, not #{value.inspect}"
    end
  end
end
