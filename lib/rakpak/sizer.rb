# frozen_string_literal: true

module Rakpak
  # Walks tagged directories on a worker thread so the UI can show a real
  # byte total and file count without ever blocking on a huge tree.
  class Sizer
    Result = Struct.new(:bytes, :files, :partial)

    BUDGET = 4.0 # seconds per path before we report a partial figure

    def initialize
      @cache = {}
      @queue = Queue.new
      @lock = Mutex.new
      @pending = {}
      @worker = Thread.new { loop { work(*@queue.pop) } }
      @worker.abort_on_exception = false
    end

    # nil means "still counting".
    def [](path)
      @lock.synchronize { @cache[path] }
    end

    def request(path)
      token = nil
      @lock.synchronize do
        return if @cache.key?(path) || @pending[path]

        token = Object.new
        @pending[path] = token
      end
      @queue << [path, token]
    end

    def total(paths)
      known = paths.map { |p| self[p] }
      bytes = known.compact.sum { |r| r.bytes }
      files = known.compact.sum { |r| r.files }
      Result.new(bytes, files, known.any?(&:nil?) || known.compact.any?(&:partial))
    end

    # Drops the figure, and any measurement in flight for it.
    def forget(path)
      @lock.synchronize do
        @cache.delete(path)
        @pending.delete(path)
      end
    end

    def invalidate!
      @lock.synchronize do
        @cache.clear
        @pending.clear
      end
    end

    private

    def work(path, token)
      res = measure(path)
      @lock.synchronize do
        # Forgotten, invalidated, or re-requested while we were walking:
        # only the walk that the current request started may answer it.
        next unless @pending[path].equal?(token)

        @pending.delete(path)
        @cache[path] = res
      end
    rescue StandardError
      @lock.synchronize { @pending.delete(path) if @pending[path].equal?(token) }
    end

    def measure(path)
      st = File.lstat(path)
      return Result.new(st.size, 1, false) unless st.directory?

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BUDGET
      bytes = 0
      files = 1 # the folder itself is an archive member
      partial = false
      stack = [path]
      until stack.empty?
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          partial = true
          break
        end
        dir = stack.pop
        begin
          Dir.children(dir).each do |name|
            child = File.join(dir, name)
            s = begin
              File.lstat(child)
            rescue StandardError
              next
            end
            if s.directory?
              stack << child
              files += 1 # tar and zip both record directory entries
            else
              bytes += s.size
              files += 1
            end
          end
        rescue StandardError
          next
        end
      end
      Result.new(bytes, files, partial)
    rescue StandardError
      Result.new(0, 0, true)
    end
  end
end
