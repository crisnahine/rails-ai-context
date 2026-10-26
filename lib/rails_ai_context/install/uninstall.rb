# frozen_string_literal: true

# Stdlib only, as the other install files: the standalone binary loads it
# before the gem entry.

module RailsAiContext
  module Install
    # Takes out everything an install wrote and nothing the user wrote:
    # every tool's generated files and MCP entries (a shared CLAUDE.md keeps
    # the user's part, an MCP config keeps other servers), the recorded
    # config, the .gitignore lines and an unchanged pre-commit hook. A mount
    # in config/routes.rb is the user's own code, so it is named, not edited.
    module Uninstall
      module_function

      # What it deletes from each app outright, edited or not: they configure
      # nothing once the gem is gone. Every other file goes through Cleanup,
      # which keeps the lines a user wrote.
      FILES = [ ".rails-ai-context.yml", Program::JSON_CACHE, "config/initializers/rails_ai_context.rb" ].freeze

      # Releases before v5.14.0 wrote the JSON cache's note with a Unicode dash.
      EARLIER_GITIGNORE_NOTES = { Program::JSON_CACHE => "# rails-ai-context (JSON cache \u2014 markdown files should be committed)" }.freeze

      # A path mark_gitignore appended, with its comment and the blank line
      # above. In bytes, as .gitignore is read: a note may hold a non-ASCII dash.
      GITIGNORE_ENTRY = Regexp.union((Program::GITIGNORE_NOTES.to_a + EARLIER_GITIGNORE_NOTES.to_a).map do |path, note|
        Regexp.new("(?:^\\r?\\n)?^#{Regexp.escape(note.b)}\\r?\\n#{Regexp.escape(path)}(?:\\r?\\n|\\z)".b)
      end)

      # `app_roots:` as for Program.cleanup_removed_tools: a folder of apps
      # keeps its MCP configs in `root` and the rest in each app. `kept`
      # collects each MCP entry that stays, a user's: { file:, name:, starts: }.
      #
      # @return [Boolean] whether anything was removed
      def call(surface, root:, app_roots: [ root ], kept: [])
        changed = Program.remove_tools(surface, AiTool.keys, selected: [], previous: AiTool.keys, root: root,
                                                             app_roots: app_roots, http_entries: true, kept: kept)

        app_roots.each do |app_root|
          changed = true if remove_files(surface, app_root: app_root, root: root)
          changed = true if remove_hook(surface, app_root: app_root)
          say_mount(surface, app_root: app_root, root: root)
        end
        [ root, *app_roots ].map(&:to_s).uniq.each { |dir| changed = true if unmark_gitignore(surface, dir: dir, root: root) }
        changed
      end

      def remove_files(surface, app_root:, root:)
        FILES.count do |relative|
          path = File.join(app_root.to_s, relative)
          next false unless File.file?(path)

          SafeFile.delete(path, root: app_root)
          surface.say "  Removed #{Program.shown(surface, path, root)}", :ok
          true
        rescue SafeFile::LinkedOut
          surface.say "Left #{Program.shown(surface, path, root)} as it is - #{SafeFile::LINKED}", :warn
          false
        rescue SystemCallError => e
          surface.say "Could not remove #{Program.shown(surface, path, root)}: #{e.message}", :warn
          false
        end.positive?
      end

      def unmark_gitignore(surface, dir:, root:)
        path = File.join(dir, ".gitignore")
        return false unless File.file?(path)

        content = File.binread(path)
        rest = content.gsub(GITIGNORE_ENTRY, "")
        return false if rest == content

        SafeFile.atomic_write(path, rest, root: dir)
        surface.say "  Removed the rails-ai-context lines from #{Program.shown(surface, path, root)}", :ok
        true
      rescue SafeFile::LinkedOut
        surface.say "Left #{Program.shown(surface, path, root)} as it is - #{SafeFile::LINKED}", :warn
        false
      rescue SystemCallError => e
        surface.say "Could not update #{Program.shown(surface, path, root)}: #{e.message}", :warn
        false
      end

      def remove_hook(surface, app_root:)
        outcome, hook, app = ValidationHook.uninstall(app_root)
        case outcome
        when :removed then surface.say "  Removed the pre-commit hook #{hook}", :ok
        when :trimmed then surface.say "  Removed #{app} from the pre-commit hook #{hook}", :ok
        when :hand_changed
          surface.say "#{hook} still runs rails-ai-context - it was changed by hand, so remove that part yourself", :warn
        end
        %i[removed trimmed].include?(outcome)
      rescue SystemCallError => e
        surface.say "Could not update the pre-commit hook: #{e.message}", :warn
        false
      end

      def say_mount(surface, app_root:, root:)
        routes = File.join(app_root.to_s, "config", "routes.rb")
        return unless File.file?(routes)

        File.foreach(routes).with_index(1) do |line, number|
          next unless line.include?("RailsAiContext::Engine") && !line.lstrip.start_with?("#")

          surface.say "#{Program.shown(surface, routes, root)}:#{number} mounts RailsAiContext::Engine - delete that line", :warn
        end
      rescue SystemCallError, ArgumentError
        nil
      end
    end
  end
end
