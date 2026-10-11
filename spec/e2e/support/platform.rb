# frozen_string_literal: true

module E2E
  # The harness runs on Linux, macOS and Windows runners, so it finds a
  # program the way the OS would rather than through `which`, which Windows
  # does not have. A spec that needs one (git for the pre-commit hook, node
  # to start a server as an AI tool does) skips with the reason when it is
  # missing.
  module Platform
    module_function

    # The path a command name resolves to on PATH, with Windows' PATHEXT
    # extensions tried, or nil.
    def executable(name)
      extensions = Gem.win_platform? ? ENV.fetch("PATHEXT", ".COM;.EXE;.BAT;.CMD").split(";") : [ "" ]
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        next if dir.empty?

        extensions.each do |extension|
          path = File.join(dir, "#{name}#{extension}")
          return path if File.file?(path) && File.executable?(path)
        end
      end
      nil
    end

    # Ends a process and every process it started. On Windows a .bat runs
    # under cmd.exe, so for `bundle exec` the child is cmd.exe and the
    # server is below it: ending cmd.exe alone left the server running,
    # holding its port and the app's files. Windows takes no TERM either.
    def kill_tree(pid)
      if Gem.win_platform?
        system("taskkill", "/T", "/F", "/PID", pid.to_s, out: File::NULL, err: File::NULL)
      else
        Process.kill("KILL", pid)
      end
    rescue SystemCallError
      nil
    end

    # Asks a process to stop: TERM where there is one. On Windows, where a
    # TERM raises, the tree is ended at once.
    def terminate(pid)
      return kill_tree(pid) if Gem.win_platform?

      Process.kill("TERM", pid)
    rescue SystemCallError
      nil
    end
  end
end
