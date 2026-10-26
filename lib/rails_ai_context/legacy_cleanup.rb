# frozen_string_literal: true

# The install path loads this file without the entry file - before Rails,
# before Zeitwerk - so it requires its own stdlib. Set is not autoloaded on
# Ruby 3.1, where `[...].to_set` raised NoMethodError.
require "set"
require_relative "safe_file"
require_relative "install/surface"

module RailsAiContext
  # One-time cleanup for files that were removed in a breaking release.
  # Handles v5.0.0's removal of design-system UI pattern rules and
  # accessibility rule files. Never deletes without explicit user consent;
  # in non-TTY environments prints a warning instead of prompting.
  module LegacyCleanup
    # Each entry: { path: relative_path, ai_tool: :claude|:cursor|:copilot }
    LEGACY_FILES = Install::AiTool.legacy_files.freeze

    module_function

    # Asks, then removes at once, for the entries outside the install program.
    #
    # @param ai_tools [Array<Symbol>, nil] formats user has selected; nil means all
    # @param root [String, Pathname] project root directory
    # @param io [IO] stream for output (stderr by default)
    # @param warn_only [Boolean] skip prompt even if TTY, only print warning
    # @param delete [Boolean] delete without asking (--prune); wins over warn_only
    # @param place [String, nil] the root as the person who typed the
    #   command names it, when they typed it outside the root: the files and
    #   the rm line are named from there, so the rm removes them where it is run
    def prompt_legacy_files(ai_tools, root:, io: $stderr, warn_only: false, place: nil, delete: false)
      surface = Install::Surface.new(->(text, _level) { io.puts text }, lambda { |prompt|
        io.print "#{prompt} "
        $stdin.gets
      }, place)
      remove(surface, ask(surface, ai_tools, root: root, warn_only: warn_only, delete: delete), root: root)
    end

    # The legacy files present and the question about them, through the
    # install's surface, named from its place.
    #
    # @return [Array<Array(String, String)>] [shown, full] pairs to delete
    def ask(surface, ai_tools, root:, warn_only: false, delete: false)
      allowed = ai_tools ? Array(ai_tools).map(&:to_sym).to_set : nil

      present = LEGACY_FILES.filter_map do |entry|
        next if allowed && !allowed.include?(entry[:ai_tool])
        full = File.join(root.to_s, entry[:path])
        [ surface.place ? File.join(surface.place, entry[:path]) : entry[:path], full ] if File.exist?(full)
      end
      return [] if present.empty?

      surface.say ""
      surface.say "Legacy files detected (removed in v5.0.0):"
      present.each { |(rel, _)| surface.say "  #{rel}" }
      surface.say ""
      surface.say "These files are no longer regenerated and contain stale guidance."
      return present if delete

      if warn_only || !$stdin.tty?
        surface.say "Delete manually when ready:"
        surface.say "  #{rm_line(present)}"
        return []
      end

      return present if %w[y yes].include?(surface.ask("Delete them? [y/N]:").to_s.strip.downcase)

      surface.say "  Kept. Delete manually when ready:"
      surface.say "    #{rm_line(present)}"
      []
    end

    # @param present [Array<Array(String, String)>] what ask returned
    def remove(surface, present, root:)
      present.each do |(rel, full)|
        SafeFile.delete(full, root: root)
        surface.say "  Removed #{rel}", :ok
      rescue SafeFile::LinkedOut
        surface.say "  Left #{rel} as it is - #{SafeFile::LINKED}", :warn
      rescue SystemCallError
        surface.say "  Could not remove #{rel} - check its permissions", :warn
      end
    end

    # The rm a reader can paste: each path a single shell word.
    def rm_line(present)
      words = present.map do |(shown, _)|
        next shown if shown.match?(%r{\A[A-Za-z0-9_\-.,:+/@]+\z})

        "'#{shown.gsub("'") { %q('\\'') }}'"
      end
      "rm -f #{words.join(' ')}"
    end
  end
end
