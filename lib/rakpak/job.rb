# frozen_string_literal: true

require_relative "plan"

module Rakpak
  # Runs a plan's steps on a worker thread, streaming output into a ring
  # buffer. The UI polls it; backgrounding is just "stop looking at it".
  class Job
    KEEP = 400

    attr_reader :plan, :state, :started_at, :finished_at, :exit_status,
                :error, :step_index, :steps, :file_count, :current_file

    def initialize(plan, total_files: nil)
      @plan = plan
      @steps = plan.steps
      @total_files = total_files
      @lines = []
      @lock = Mutex.new
      @state = :pending
      @step_index = 0
      @file_count = 0
      @current_file = nil
      @verbose = true
      @cancel = false
      @pid = nil
      @spawned = nil # output path of the step currently being written
      @started_at = nil
      @finished_at = nil
    end

    def start
      @started_at = now
      @state = :running
      @thread = Thread.new { run_all }
      @thread.abort_on_exception = false
      self
    end

    def running? = @state == :running
    def done? = %i[done failed cancelled].include?(@state)
    def ok? = @state == :done

    def elapsed
      return 0 unless @started_at

      (@finished_at || now) - @started_at
    end

    def tail(n)
      @lock.synchronize { @lines.last(n).dup }
    end

    def label
      @lock.synchronize { @steps[[@step_index, @steps.size - 1].min]&.first || "archive" }
    end

    def total_files = @total_files

    # nil when there is nothing to measure progress against: no file total,
    # or a step whose tool is not listing members (verbose off).
    def fraction
      return nil unless @total_files&.positive? && @verbose

      per = 1.0 / @steps.size
      base = @step_index * per
      [base + (per * [@file_count.to_f / @total_files, 1.0].min), 1.0].min
    end

    # Bytes on disk for whatever this step is writing right now.
    def output_size
      out = @plan.outputs[[@step_index, @plan.outputs.size - 1].min]
      return nil unless out

      File.size(out)
    rescue StandardError
      nil
    end

    def summary
      @plan.outputs.map do |o|
        size = begin
          File.size(o)
        rescue StandardError
          nil
        end
        [File.basename(o), size]
      end
    end

    def cancel
      @cancel = true
      kill_current
    end

    # Blocks until the worker is finished, for at most `secs`.
    def wait(secs = nil) = @thread&.join(secs)

    private

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def kill_current
      pid = @pid
      return unless pid

      begin
        Process.kill("TERM", -pid) # the whole group: tar and its compressor
      rescue StandardError
        nil
      end
      Thread.new do
        sleep 2
        # Once waitpid has reaped it the pid may belong to someone else.
        next unless @pid == pid

        begin
          Process.kill("KILL", -pid)
        rescue StandardError
          nil
        end
      end
    end

    def push(line)
      return if line.empty?

      @lock.synchronize do
        @lines << line
        @lines.shift(@lines.size - KEEP) if @lines.size > KEEP
      end
    end

    def run_all
      @steps.each_with_index do |(label, argv, verbose, stdout), idx|
        @step_index = idx
        @file_count = 0
        @verbose = verbose
        # A cancel that lands between steps must not start the next one.
        return finish(:cancelled) if @cancel

        push("▸ #{label}: #{Plan.show_cmd(argv, stdout)}")
        status = run_step(argv, stdout)
        return finish(:cancelled) if @cancel

        unless status&.success?
          @error = failure_message(label, status)
          return finish(:failed)
        end
        @spawned = nil
      end
      finish(:done)
    rescue StandardError => e
      @error = "#{e.class}: #{e.message}"
      finish(:failed)
    end

    def failure_message(label, status)
      # status is nil when the command could not be spawned at all; in that
      # case run_step already recorded the useful message.
      return @error || "#{label} could not be started" if status.nil?

      if status.signaled?
        name = Signal.signame(status.termsig) || status.termsig.to_s
        return "#{label} killed by SIG#{name}"
      end
      @exit_status = status.exitstatus
      "#{label} exited with status #{@exit_status}"
    end

    def finish(state)
      cleanup_incomplete if %i[failed cancelled].include?(state)
      @state = state
      @finished_at = now
    end

    # A half-written archive is worse than no archive: it opens, lists a few
    # members, then fails. Remove it, but only the output of the step that
    # was actually interrupted. Archives finished by earlier steps are whole
    # and must survive, and a step that never spawned wrote nothing.
    def cleanup_incomplete
      path = @spawned
      return unless path && File.exist?(path)

      File.unlink(path)
      push("removed incomplete #{File.basename(path)}")
    rescue StandardError => e
      push("could not remove #{File.basename(path)}: #{e.message}")
    end

    # `stdout` names a file the command's output is the archive for (gzip -c);
    # otherwise stdout joins stderr in the log.
    def run_step(argv, stdout = nil)
      out = @plan.outputs[@step_index]
      # Every tool here is asked to create the archive, and the confirm
      # screen has said an existing one will be overwritten. zip would
      # otherwise update it in place, keeping members that no longer exist.
      File.unlink(out) if out && File.exist?(out)
      @spawned = out

      rd, wr = IO.pipe
      begin
        pid = Process.spawn(*argv, out: stdout ? [stdout, "wb"] : wr, err: wr, in: File::NULL,
                                   pgroup: true, chdir: @plan.base)
      rescue StandardError => e
        # Nothing was spawned, so nothing will close these for us.
        rd.close
        wr.close
        @error = e.message
        return nil
      end
      wr.close
      @pid = pid
      # A cancel that raced the spawn saw no pid to signal; do it now.
      kill_current if @cancel

      buf = String.new("", encoding: Encoding::UTF_8)
      begin
        loop do
          chunk = begin
            rd.read_nonblock(16_384)
          rescue IO::WaitReadable
            IO.select([rd], nil, nil, 0.25)
            next
          rescue EOFError
            break
          end
          # A pipe hands back binary. Filenames are arbitrary bytes, so this
          # has to be made printable before it can meet the UTF-8 frame.
          buf << chunk.force_encoding(Encoding::UTF_8).scrub("·")
          # tar emits newlines, zip rewrites lines with \r.
          while (m = buf.match(/[\r\n]/))
            line = buf.slice!(0, m.end(0)).chomp("\n").chomp("\r").rstrip
            record(line)
          end
        end
      ensure
        record(buf.rstrip) unless buf.strip.empty?
        rd.close unless rd.closed?
      end

      _, status = Process.waitpid2(@pid)
      @pid = nil
      status
    end

    def record(line)
      return if line.empty?

      case line
      when /\A\s*(?:adding|updating|deflated|stored):\s*(.+?)(?:\s*\(|\z)/
        @file_count += 1
        @current_file = Regexp.last_match(1)
      when /\A(?:tar|zip|gzip|zstd|xz|bzip2|brotli|lz4):/, /\A\s*(?:total bytes|zip warning)/
        @current_file = line
      else
        # Without -v the only lines are diagnostics, not members.
        @file_count += 1 if @verbose
        @current_file = line
      end
      push(line)
    end
  end
end
