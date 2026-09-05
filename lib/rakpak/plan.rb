# frozen_string_literal: true

require_relative "formats"

module Rakpak
  # Turns a set of tagged paths plus the wizard's answers into one concrete
  # command. Nothing here shells out; commands are spawned without a shell,
  # so spaces and quotes in filenames are never a hazard.
  #
  # Three shapes of output, one file each:
  #   :both   tar, then compress            name.tar.gz, name.tar.zst, ...
  #   :tar    plain tar, no compression     name.tar
  #   :zip    compression only              name.zip, or name.txt.gz for one file
  class Plan
    TARGETS = %i[both tar zip].freeze

    attr_reader :paths
    attr_accessor :outdir, :basename, :target
    attr_accessor :tar_codec, :tar_level, :tar_flags, :compressor, :comp_level, :zip_flags

    def initialize(paths:, outdir:, basename: "archive", target: :both)
      @paths = self.class.prune(paths)
      @outdir = outdir
      @basename = basename
      @target = target
      # gzip is the one every system can read; anything else is opt-in.
      @tar_codec = TAR_CODECS.find { |c| c.id == :gzip && c.available? } || tar_codec_fallback
      @tar_level = @tar_codec.default
      @tar_flags = Rakpak.tar_flags
      @compressor = COMPRESSORS.find { |c| c.container? && c.available? } || COMPRESSORS.first
      @comp_level = @compressor.default
      @zip_flags = Rakpak.zip_flags
    end

    # Drop anything already covered by another selection: tagging ~/docs and
    # then ~/docs/notes would otherwise store notes twice, silently.
    def self.prune(paths)
      # Sorting by path components puts every descendant right after its
      # ancestor ("a/b" before "a-x"), so one pass with a stack of accepted
      # ancestors is enough, however many paths there are.
      sorted = paths.map { |p| File.expand_path(p) }.uniq.sort_by { |p| p.split("/") }
      kept = []
      stack = []
      sorted.each do |p|
        stack.pop while stack.any? && !inside?(p, stack.last)
        next if stack.any?

        kept << p
        stack << p
      end
      kept
    end

    def self.inside?(path, dir)
      path.start_with?(dir == "/" ? "/" : "#{dir}/")
    end

    # "none" needs no tool so it is always available; it is the last
    # resort, not the first pick, when gzip is missing.
    def tar_codec_fallback
      TAR_CODECS.find { |c| c.bin && c.available? } || Rakpak.tar_codec(:none)
    end

    # One format's knobs behind a uniform face, so the option form does not
    # need to know whether it is editing tar or compressor settings. Picking
    # a codec resets the level to that codec's default.
    class Side
      attr_reader :options, :flags

      def initialize(plan, options:, codec:, level:, flags:, choices:)
        @plan = plan
        @options = options
        @codec_attr = codec
        @level_attr = level
        @flags = flags
        @choices = choices
      end

      def codec = @plan.public_send(@codec_attr)
      def level = @plan.public_send(@level_attr)
      def level=(v)
        @plan.public_send("#{@level_attr}=", v)
      end

      # [label, id, enabled, why] rows for the form's choice list.
      def choices = @plan.public_send(@choices)

      def codec=(id)
        c = @options.find { |o| o.id == id } or raise ArgumentError, "unknown codec #{id}"
        @plan.public_send("#{@codec_attr}=", c)
        self.level = c.default
      end
    end

    def tar
      Side.new(self, options: TAR_CODECS, codec: :tar_codec, level: :tar_level,
                     flags: @tar_flags, choices: :tar_choices)
    end

    def compress
      Side.new(self, options: COMPRESSORS, codec: :compressor, level: :comp_level,
                     flags: @zip_flags, choices: :compress_choices)
    end

    # "both" means compressed, so "none" is not on offer there.
    def tar_choices
      TAR_CODECS.reject { |c| c.id == :none }.map { |c| [c.label, c.id, c.available?, c.why_not] }
    end

    # Single-file compressors only make sense for exactly one file; zip can
    # take anything.
    def compress_choices
      COMPRESSORS.map do |c|
        ok = c.available? && (c.container? || single_file?)
        why = c.why_not || "compresses one file only; choose both for folders"
        [c.label, c.id, ok, ok ? nil : why]
      end
    end

    def single_file? = @paths.size == 1 && File.file?(@paths.first)

    # True when the output is a bare compressed file (notes.txt.gz), where
    # the original name should be kept whole.
    def single_compress? = @target == :zip && !@compressor.container?

    # Deepest directory containing every tagged path. Members are stored
    # relative to it, so the archive has a sane shape no matter how far
    # apart the selections were.
    def base
      @base ||= begin
        dirs = @paths.map { |p| File.dirname(p) }
        common = dirs.first.to_s.split("/")
        dirs.each do |d|
          parts = d.split("/")
          i = 0
          i += 1 while i < common.size && i < parts.size && common[i] == parts[i]
          common = common[0...i]
        end
        c = common.join("/")
        c.empty? ? "/" : c
      end
    end

    def members
      @paths.map do |p|
        rel = p.delete_prefix(base == "/" ? "/" : "#{base}/")
        rel.empty? ? File.basename(p) : rel
      end
    end

    def ext
      case @target
      when :both then @tar_codec.ext
      when :tar then ".tar"
      else @compressor.container? ? ".zip" : @compressor.single_ext
      end
    end

    def output = File.join(@outdir, ensure_ext(@basename, ext))
    def outputs = [output]

    # Extensions a user might type that we would otherwise double up.
    ARCHIVE_EXTS = (TAR_CODECS.map(&:ext) + TAR_CODECS.map(&:single_ext) + %w[.tgz .tbz2 .txz .zip])
                   .reject(&:empty?).uniq.sort_by { |e| -e.length }.freeze

    def ensure_ext(name, ext)
      return name if name.downcase.end_with?(ext)
      # backup.tar gzipped on its own is backup.tar.gz; the name is the
      # point, so nothing is stripped from it.
      return "#{name}#{ext}" if single_compress?

      # Strip a competing archive extension the user may have typed.
      typed = ARCHIVE_EXTS.find { |e| name.downcase.end_with?(e) }
      stripped = typed ? name[0...-typed.length] : name
      stripped = name if stripped.empty?
      "#{stripped}#{ext}"
    end

    def tar_argv
      argv = ["tar", "-c"]
      if @target == :both && (filter = @tar_codec.filter(@tar_level))
        argv += ["--use-compress-program", filter]
      end
      @tar_flags.each { |f| argv.concat(f.args) if f.on }
      argv += ["-f", output, "-C", base, "--"]
      argv + members
    end

    def zip_argv
      argv = ["zip", "-r"]
      argv << (zip_verbose? ? "-v" : "-q")
      argv << "-Z" << @compressor.flag if @compressor.flag != "deflate"
      argv << "-#{@comp_level.clamp(0, 9)}" if @compressor.levels && @comp_level
      argv << "-D" unless flag_on?(@zip_flags, :dirs)
      @zip_flags.each do |f|
        next if %i[verbose dirs].include?(f.id)

        argv.concat(f.args) if f.on
      end
      argv << output
      argv + members.map { |m| dashsafe(m) }
    end

    # gzip and friends read one file and write to stdout; the job redirects
    # that into the output path.
    def single_argv
      @compressor.argv(@comp_level) + [dashsafe(members.first)]
    end

    def dashsafe(name) = name.start_with?("-") ? "./#{name}" : name

    def zip_verbose? = flag_on?(@zip_flags, :verbose)
    def tar_verbose? = flag_on?(@tar_flags, :verbose)

    def flag_on?(list, id)
      f = list.find { |x| x.id == id }
      f ? f.on : false
    end

    # [label, argv, expects_verbose_output, stdout_path]
    def steps
      case @target
      when :both, :tar then [["tar", tar_argv, tar_verbose?, nil]]
      else
        if @compressor.container?
          [["zip", zip_argv, zip_verbose?, nil]]
        else
          [[@compressor.label, single_argv, false, output]]
        end
      end
    end

    # Display form of the command. Execution never goes through a shell, so
    # this is for the reader's benefit; quote only what needs it.
    def self.show_arg(arg)
      arg.match?(%r{\A[\w@%+=:,./-]+\z}) ? arg : "'#{arg.gsub("'", %q('"'"'))}'"
    end

    def self.show_cmd(argv, stdout = nil)
      cmd = argv.map { |a| show_arg(a) }.join(" ")
      stdout ? "#{cmd} > #{show_arg(stdout)}" : cmd
    end

    def preview
      steps.map { |(label, argv, _, stdout)| [label, Plan.show_cmd(argv, stdout)] }
    end

    # Problems worth blocking on, checked right before the run.
    def problems
      errs = []
      errs << "nothing selected" if @paths.empty?
      errs << "destination is not a folder: #{@outdir}" unless File.directory?(@outdir)
      errs << "destination is not writable: #{@outdir}" if File.directory?(@outdir) && !File.writable?(@outdir)
      case @target
      when :both
        errs << "tar is not installed" unless Tools.available?("tar")
        errs << @tar_codec.why_not if @tar_codec.why_not
        errs << "no compressor installed; choose tarball" if @tar_codec.id == :none
      when :tar
        errs << "tar is not installed" unless Tools.available?("tar")
      else
        errs << @compressor.why_not if @compressor.why_not
        if !@compressor.container? && !single_file?
          errs << "#{@compressor.label} compresses one file only; choose both for folders"
        end
      end
      errs.compact.uniq
    end

    # Non-blocking things the confirm screen should say out loud.
    def warnings
      warn = []
      o = output
      warn << "#{File.basename(o)} already exists and will be replaced" if File.exist?(o)
      if @paths.any? { |p| Plan.inside?(o, p) }
        warn << "output sits inside a selected folder, so it may archive itself"
      end
      warn
    end
  end
end
