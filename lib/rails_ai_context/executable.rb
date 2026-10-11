# frozen_string_literal: true

module RailsAiContext
  # Whether a bare command name would start, found on PATH the way the
  # platform's own lookup finds it: Windows tries each PATHEXT extension.
  # `which` is not on every platform this runs on, and a shell string
  # (`which rg > /dev/null`) is not portable either.
  module Executable
    module_function

    def on_path?(command, path: ENV["PATH"])
      extensions = Gem.win_platform? ? [ "", *ENV.fetch("PATHEXT", ".EXE;.BAT;.CMD").split(";") ] : [ "" ]
      path.to_s.split(File::PATH_SEPARATOR).reject(&:empty?).any? do |dir|
        extensions.any? do |ext|
          file = File.join(dir, "#{command}#{ext}")
          File.file?(file) && File.executable?(file)
        end
      end
    end
  end
end
