# frozen_string_literal: true

module RailsAiContext
  # Redirects $stdout to $stderr for the duration of a block. The stdio MCP
  # transport carries JSON-RPC on stdout, so anything the host app prints
  # while booting (initializer puts, gem banners, deprecation warnings)
  # corrupts the protocol handshake and the client reports a dead server.
  #
  # Swaps the $stdout global AND reopens file descriptor 1 onto $stderr's
  # target. The global swap catches puts/print (which read $stdout); the fd
  # reopen additionally catches code that writes through the STDOUT constant
  # directly, and any subprocess that inherits fd 1 from this process. Code
  # that dup'd fd 1 before this method runs holds its own descriptor pointing
  # at the original target and stays out of reach either way.
  #
  # The fd reopen only happens when $stderr is backed by a real file
  # descriptor. Unit specs commonly swap $stderr for a StringIO, and
  # STDOUT.reopen(StringIO) raises TypeError - that case falls back to the
  # global-swap-only behavior above.
  #
  # Dependency-free on purpose: standalone mode loads this file before the
  # host app's Bundler.setup runs, so it must not pull in the rest of the gem.
  module OutputGuard
    # The descriptor the real stdout lives on, handed to a process that
    # re-execs itself while the quarantine is up.
    STDOUT_FD_ENV = "RAILS_AI_CONTEXT_STDOUT_FD"

    def self.quarantine_stdout
      original = $stdout
      saved_stdout = reopenable_target? ? saved_stdout_io : nil
      inherited_env = ENV[STDOUT_FD_ENV]
      if saved_stdout
        # `exec` closes a dup'd descriptor unless close-on-exec is cleared,
        # and the new image would then save fd 1 - by then pointing at
        # stderr - as its "stdout" and write every MCP response there.
        # Bundler re-execs exactly here: `require "bundler/setup"` runs
        # inside this block, and auto_switch re-execs when the lockfile
        # names a different Bundler than the one running.
        saved_stdout.close_on_exec = false
        ENV[STDOUT_FD_ENV] = saved_stdout.fileno.to_s
        STDOUT.reopen($stderr)
      end
      $stdout = $stderr
      yield
    ensure
      if saved_stdout
        STDOUT.reopen(saved_stdout)
        saved_stdout.close
        inherited_env ? ENV[STDOUT_FD_ENV] = inherited_env : ENV.delete(STDOUT_FD_ENV)
      end
      $stdout = original
    end

    # The descriptor an earlier image of this process saved, when there is
    # one and it is still open; a fresh dup of fd 1 otherwise.
    def self.saved_stdout_io
      inherited = ENV[STDOUT_FD_ENV]
      (inherited && io_for_fd(inherited.to_i)) || STDOUT.dup
    end
    private_class_method :saved_stdout_io

    def self.io_for_fd(fd)
      return nil unless fd.positive?

      io = IO.new(fd, "w", autoclose: false)
      io.stat
      io
    rescue StandardError
      nil
    end
    private_class_method :io_for_fd

    # True when $stderr has a real file descriptor STDOUT.reopen can target -
    # false for StringIO and other fd-less doubles, and false if $stderr has
    # already been closed.
    def self.reopenable_target?
      $stderr.respond_to?(:fileno) && $stderr.fileno.is_a?(Integer)
    rescue IOError, Errno::EBADF
      false
    end
    private_class_method :reopenable_target?
  end
end
