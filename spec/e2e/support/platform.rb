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
  end
end
