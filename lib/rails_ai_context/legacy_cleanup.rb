# frozen_string_literal: true

# The install path loads this file without the entry file - before Rails,
# before Zeitwerk - so it requires its own stdlib. Set is not autoloaded on
# Ruby 3.1, where `[...].to_set` raised NoMethodError.
require "set"

module RailsAiContext
  # One-time cleanup for files that were removed in a breaking release.
  # Handles v5.0.0's removal of design-system UI pattern rules and
  # accessibility rule files. Never deletes without explicit user consent;
  # in non-TTY environments prints a warning instead of prompting.
  module LegacyCleanup
    # Each entry: { path: relative_path, ai_tool: :claude|:cursor|:copilot }
    LEGACY_FILES = Install::AiTool.legacy_files.freeze

    module_function

    # @param ai_tools [Array<Symbol>, nil] formats user has selected; nil means all
    # @param root [String, Pathname] project root directory
    # @param io [IO] stream for output (stderr by default)
    # @param warn_only [Boolean] skip prompt even if TTY, only print warning
    def prompt_legacy_files(ai_tools, root:, io: $stderr, warn_only: false)
      allowed = ai_tools ? Array(ai_tools).map(&:to_sym).to_set : nil

      present = LEGACY_FILES.filter_map do |entry|
        next if allowed && !allowed.include?(entry[:ai_tool])
        full = File.join(root.to_s, entry[:path])
        [ entry[:path], full ] if File.exist?(full)
      end
      return if present.empty?

      io.puts ""
      io.puts "Legacy files detected (removed in v5.0.0):"
      present.each { |(rel, _)| io.puts "  #{rel}" }
      io.puts ""
      io.puts "These files are no longer regenerated and contain stale guidance."

      if warn_only || !$stdin.tty?
        io.puts "Delete manually when ready:"
        io.puts "  rm -f #{present.map(&:first).join(' ')}"
        return
      end

      io.print "Delete them? [y/N]: "
      input = $stdin.gets&.strip&.downcase || "n"

      if input == "y" || input == "yes"
        require "fileutils"
        present.each do |(rel, full)|
          FileUtils.rm_f(full)
          io.puts "  Removed #{rel}"
        end
      else
        io.puts "  Kept. Delete manually when ready:"
        io.puts "    rm -f #{present.map(&:first).join(' ')}"
      end
    end
  end
end
