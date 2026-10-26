# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require_relative "cli/refusal"

module RailsAiContext
  # An MCP server run as a child over stdio: one per app under the router
  # (WorkspaceServer), and the app's bundled copy behind the plugin's proxy.
  # Stdlib only, since the proxy starts before any app boots.
  class ChildServer
    # Raised where the child stopped before it answered; the message is what it said last.
    class Gone < StandardError; end

    # `ruby` on PATH, which a version manager's shim resolves in the folder the child starts in; this Ruby without one.
    def self.ruby(path)
      names = Gem.win_platform? ? %w[ruby.exe ruby.bat ruby.cmd] : %w[ruby]
      path.to_s.split(File::PATH_SEPARATOR).each do |dir|
        names.each do |name|
          file = File.join(dir, name)
          return file if File.file?(file) && File.executable?(file)
        end
      end
      RbConfig.ruby
    end

    # Passes each line on, so the session stays connected where an app's own copy of the gem stops: before
    # `initialize` the refusal answers with what it said, after it each request still open gets an error naming that.
    def self.proxy(env, argv, chdir:, name:, io_in:, io_out:)
      out = Mutex.new
      emit = lambda do |text|
        out.synchronize do
          io_out.puts text
          io_out.flush
        end
      end
      lock = Mutex.new
      pending = {}
      state = { ready: false }
      local = lambda do |request, reason|
        answer = if lock.synchronize { state[:ready] }
          { "error" => { "code" => -32_603, "message" => "#{name} stopped: #{reason}" } }
        else
          CLI::Refusal.answer(request, "#{name} could not start: #{reason}")
        end
        emit.(JSON.generate({ "jsonrpc" => "2.0", "id" => request["id"] }.merge(answer)))
      end
      child = new(env, argv, chdir: chdir) do |line, message|
        if message.key?("id") && !message.key?("method")
          lock.synchronize do
            asked = pending.delete(message["id"])
            state[:ready] = true if asked && asked["method"] == "initialize" && message.key?("result")
          end
        end
        emit.(line.chomp)
      end
      child.on_exit do |reason|
        left = lock.synchronize { state[:reason] = reason; pending.values.tap { pending.clear } }
        left.each { |request| local.(request, reason) }
      end

      io_in.each_line do |line|
        message = CLI::Refusal.parse(line) or next
        asks = message.key?("id") && message.key?("method")
        reason = lock.synchronize do
          pending[message["id"]] = message if asks && !state[:reason]
          state[:reason]
        end
        next local.(message, reason) if reason && asks
        next if reason

        begin
          child.write(line.chomp)
        rescue Gone
          nil
        end
      end
    ensure
      child&.stop
    end

    # `on_message` gets each line the child writes that is no answer to #request, with its parse and the child.
    def initialize(env, argv, chdir:, &on_message)
      @on_message = on_message
      @lock = Mutex.new
      @write = Mutex.new
      @once = Mutex.new
      @pending = {}
      @next_id = 0
      @log = []
      @exits = []
      @stdin, stdout, stderr, @wait = Open3.popen3(env, *argv, chdir: chdir)
      @errors = Thread.new { relay(stderr) }
      @reader = Thread.new { read(stdout) }
    rescue SystemCallError => e
      @reason = CLI::Refusal.utf8(e.message)
    end

    def gone?
      @lock.synchronize { !@reason.nil? }
    end

    # Runs once the child has stopped, with what it said last; at once where it has.
    def on_exit(&block)
      reason = @lock.synchronize do
        @exits << block unless @reason
        @reason
      end
      block.call(reason) if reason
    end

    # The block runs once, the first time it returns without raising.
    def once
      @once.synchronize do
        next if @ready

        yield
        @ready = true
      end
    end

    def request(method, params)
      queue = Queue.new
      id = @lock.synchronize do
        raise Gone, @reason if @reason

        @pending[@next_id += 1] = queue
        @next_id
      end
      write(JSON.generate({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }))
      answer = queue.pop
      raise answer if answer.is_a?(Gone)

      answer
    end

    def notify(method)
      write(JSON.generate({ "jsonrpc" => "2.0", "method" => method }))
    end

    def write(line)
      raise Gone, @reason unless @stdin

      @write.synchronize do
        @stdin.puts line
        @stdin.flush
      end
    rescue IOError, SystemCallError
      @reader&.join(5)
      raise Gone, @reason || "its input closed"
    end

    def stop
      return unless @wait

      @write.synchronize { @stdin.close unless @stdin.closed? }
      unless @wait.join(5)
        Process.kill("KILL", @wait.pid)
        @wait.join(1)
      end
      @reader.join(1)
    rescue SystemCallError, IOError
      nil
    end

    private

    # The child's log goes on to this process's, and its last lines answer for it once it stops.
    def relay(stderr)
      stderr.each_line do |line|
        $stderr.write(line)
        @log << line.chomp
        @log.shift if @log.size > 20
      end
    rescue IOError
      nil
    end

    def read(stdout)
      while (line = stdout.gets)
        message = CLI::Refusal.parse(line) or next
        queue = message.key?("id") && !message.key?("method") ? @lock.synchronize { @pending.delete(message["id"]) } : nil
        queue ? queue << message : @on_message&.call(line, message, self)
      end
    rescue IOError, SystemCallError
      nil
    ensure
      finish
    end

    # The reason is read once the child and its stderr are done, so its last line is never cut off.
    def finish
      @wait.join(1)
      @errors.join(1)
      said = @log.last(5).join(" ").strip
      said = quiet_reason(@wait.alive? ? nil : @wait.value) if said.empty?
      pending, exits = @lock.synchronize do
        @reason = CLI::Refusal.utf8(said)
        [ @pending.values, @exits ].tap { @pending = {} }
      end
      pending.each { |queue| queue << Gone.new(@reason) }
      exits.each { |block| block.call(@reason) }
    end

    def quiet_reason(status)
      return "it exited with status #{status.exitstatus}" if status&.exitstatus
      return "it was stopped by signal #{Signal.signame(status.termsig)}" if status&.signaled?

      "it closed its output"
    end
  end
end
