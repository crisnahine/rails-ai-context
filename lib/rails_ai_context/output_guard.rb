# frozen_string_literal: true

module RailsAiContext
  # Redirects $stdout to $stderr for the duration of a block. The stdio MCP
  # transport carries JSON-RPC on stdout, so anything the host app prints
  # while booting (initializer puts, gem banners, deprecation warnings)
  # corrupts the protocol handshake and the client reports a dead server.
  #
  # Swaps the $stdout global rather than reopening the file descriptor:
  # code that captured the STDOUT constant before the swap still writes to
  # the real stream, but boot-time output overwhelmingly goes through
  # puts/print, which use $stdout.
  #
  # Dependency-free on purpose: standalone mode loads this file before the
  # host app's Bundler.setup runs, so it must not pull in the rest of the gem.
  module OutputGuard
    def self.quarantine_stdout
      original = $stdout
      $stdout = $stderr
      yield
    ensure
      $stdout = original
    end
  end
end
