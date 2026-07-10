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
    def self.quarantine_stdout
      original = $stdout
      saved_stdout = reopenable_target? ? STDOUT.dup : nil
      STDOUT.reopen($stderr) if saved_stdout
      $stdout = $stderr
      yield
    ensure
      if saved_stdout
        STDOUT.reopen(saved_stdout)
        saved_stdout.close
      end
      $stdout = original
    end

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
