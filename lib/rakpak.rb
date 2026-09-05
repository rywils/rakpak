# frozen_string_literal: true

require_relative "rakpak/version"
require_relative "rakpak/app"

module Rakpak
  USAGE = <<~USAGE
    rakpak: tag files anywhere, archive them once.

    usage: rakpak [folder]
           rakpak -p path [path ...]

      folder         start browsing there (default: your home folder)
      -p, --pack     tag the given files or folders and go straight to the
                     archive prompts, starting with the kind of compression
      -h, --help     this text
      -v, --version  print the version

      space      tag / untag       p    pack what is tagged
      h l ← →   navigate           /    filter      .  hidden
      enter      enter folder       T    review tags
      ?          all keys           q    quit
  USAGE

  Options = Struct.new(:dir, :pack, :action, keyword_init: true)

  # A folder as a person would type it: ~, ~/x, $HOME/x, ${HOME}/x, or an
  # absolute or relative path.
  def self.expand_dir(text)
    text = text.to_s.strip
    text = text.gsub(/\$\{(\w+)\}|\$(\w+)/) { ENV.fetch(::Regexp.last_match(1) || ::Regexp.last_match(2), "") }
    text = "~" if text.empty?
    File.expand_path(text)
  rescue ArgumentError
    text # ~nosuchuser and the like; the caller reports it is not a folder
  end

  # Returns Options. `action` is :browse, :help or :version. Raises
  # ArgumentError on anything it does not understand.
  def self.parse(argv)
    pack_mode = false
    positional = []
    rest = argv.dup
    until rest.empty?
      arg = rest.shift
      case arg
      when "-h", "--help" then return Options.new(action: :help)
      when "-v", "--version" then return Options.new(action: :version)
      when "-p", "--pack" then pack_mode = true
      when "--" then positional.concat(rest) && rest.clear
      when /\A-./ then raise ArgumentError, "unknown option: #{arg}"
      else positional << arg
      end
    end

    if pack_mode
      raise ArgumentError, "-p needs at least one path" if positional.empty?

      paths = positional.map { |p| File.expand_path(p) }
      paths.each do |p|
        raise ArgumentError, "no such file or folder: #{p}" unless File.exist?(p) || File.symlink?(p)
      end
      # Open the browser on the folder holding the first target, with that
      # target under the cursor, so the archive lands next to it.
      Options.new(action: :browse, dir: File.dirname(paths.first), pack: paths)
    else
      raise ArgumentError, "expected one folder, got #{positional.size}" if positional.size > 1

      dir = File.expand_path(positional.first || Dir.home)
      raise ArgumentError, "not a folder: #{dir}" unless File.directory?(dir)

      Options.new(action: :browse, dir: dir, pack: [])
    end
  end

  # Exit status.
  def self.start(argv = ARGV)
    begin
      opts = parse(argv)
    rescue ArgumentError => e
      warn "rakpak: #{e.message}"
      warn "try: rakpak --help"
      return 2
    end
    case opts.action
    when :help
      puts USAGE
      return 0
    when :version
      puts "rakpak #{VERSION}"
      return 0
    end
    unless $stdout.tty? && $stdin.tty?
      warn "rakpak: needs an interactive terminal"
      return 1
    end
    App.new(opts.dir, pack: opts.pack).run
    0
  end
end
