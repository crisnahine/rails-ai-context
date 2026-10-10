# frozen_string_literal: true

# Stdlib only: the standalone binary loads this before the gem entry, so it
# must stand alone the way the other install files do.
require "open3"
require "pathname"

module RailsAiContext
  module Install
    # The interactive install program: which tools, which mode, what to clean
    # up, what lands in .gitignore, and which MCP configs get written. Three
    # entry points ran a full copy each (~470 lines), and the copies drifted
    # where the eye cannot check - two labels for one mode, a menu that
    # showed file lists in two entries and bare names in the third.
    #
    # Entries supply a surface - say(text, level) and ask(prompt) - and keep
    # only their own voice (Thor colours, $stderr, puts) and their closing
    # instructions, which genuinely differ per invocation form.
    module Program
      module_function

      # @param surface [#say, #ask] ask returns the user's line, nil on EOF
      # @param current [Array<Symbol>, nil] what an earlier run recorded,
      #   shown above the question so a re-run starts from it
      # @return [Array<Symbol>] never empty; every tool when nothing usable
      #   was entered, and an answer that named no tool says so.
      def select_ai_tools(surface, current: nil)
        tools = AiTool.all
        surface.say ""
        surface.say "Which AI tools do you use? (select all that apply)", :emph
        surface.say ""
        tools.each { |t| surface.say "  #{t.number}. #{t.name.ljust(16)} -> #{t.files}" }
        surface.say "  a. All of the above"
        surface.say ""
        chosen = tools.select { |t| Array(current).map(&:to_sym).include?(t.key) }
        if chosen.any?
          surface.say "Currently selected: #{chosen.map(&:number).join(',')} (#{chosen.map(&:name).join(', ')})"
          surface.say ""
        end

        input = surface.ask("Enter numbers separated by commas (e.g. 1,2) or 'a' for all:").to_s.strip.downcase

        selected = if input == "a" || input == "all"
          tools.map(&:key)
        else
          by_number = tools.to_h { |t| [ t.number, t.key ] }
          input.split(/[\s,]+/).filter_map { |n| by_number[n] }
        end

        # An empty answer is the documented default, all of them, and the
        # Selected line below says so. Only an answer that named nothing
        # usable gets a line of its own.
        if selected.empty?
          surface.say "#{input.inspect} names no tool - selecting all.", :emph unless input.empty?
          selected = tools.map(&:key)
        end

        names = tools.select { |t| selected.include?(t.key) }.map(&:name)
        surface.say "Selected: #{names.join(', ')}", :ok
        selected
      end

      # What this install writes. Answers 1 and 2 keep the meaning they have
      # always had, so anything piping input into the installer still works.
      Setup = Struct.new(:tool_mode, :context_files)

      def select_setup(surface)
        surface.say ""
        surface.say "What should rails-ai-context write?", :emph
        surface.say ""
        surface.say "  1. MCP config + context files   (default)"
        surface.say "  2. Context files only           (CLI mode, no MCP server)"
        surface.say "  3. MCP config only              (leaves CLAUDE.md, AGENTS.md and rules untouched)"
        surface.say ""

        input = surface.ask("Enter number (default: 1):").to_s.strip
        setup = case input
        when "2" then Setup.new(:cli, true)
        when "3" then Setup.new(:mcp, false)
        else Setup.new(:mcp, true)
        end
        surface.say "Selected: #{setup_label(setup)}", :ok
        setup
      end

      def setup_label(setup)
        return "MCP config only (no context files)" unless setup.context_files

        setup.tool_mode == :mcp ? "MCP + CLI fallback" : "CLI only"
      end

      # Offers to remove what a re-run dropped from the selection, and
      # removes it. `keeping:` protects files the remaining tools share
      # (AGENTS.md).
      #
      # `app_roots:` names where the context files live when that is not
      # `root`: a workspace keeps them in each app and its MCP entries in
      # itself. Paths are reported relative to `root` either way.
      def cleanup_removed_tools(surface, previous:, selected:, root:, app_roots: [ root ])
        to_remove = ask_removed_tools(surface, previous: previous, selected: selected)
        remove_tools(surface, to_remove, selected: selected, root: root, app_roots: app_roots)
      end

      # The question half of the cleanup, for an entry that asks everything
      # before it writes anything.
      #
      # @return [Array<Symbol>] the dropped tools whose files are to go
      def ask_removed_tools(surface, previous:, selected:)
        removed = Array(previous).map(&:to_sym) - selected.map(&:to_sym)
        return [] if removed.empty?

        surface.say ""
        surface.say "These AI tools were removed from your selection:", :emph
        removed.each_with_index do |key, idx|
          tool = AiTool.find(key)
          surface.say "  #{idx + 1}. #{tool.name} (#{tool.files})" if tool
        end
        surface.say ""
        surface.say "Remove their generated files?", :emph
        surface.say "  y - remove all listed above"
        surface.say "  n - keep all (default)"
        surface.say "  1,2 - remove only specific ones by number"
        surface.say ""

        input = surface.ask("Enter choice:").to_s.strip.downcase
        return [] if input.empty? || input == "n" || input == "no"
        return removed if %w[y yes a].include?(input)

        nums = input.split(/[\s,]+/).filter_map { |n| n.to_i - 1 }
        nums.filter_map { |i| removed[i] if i >= 0 && i < removed.size }
      end

      # The doing half: each tool's generated files and MCP entries go, and
      # every file it shares with a tool still selected stays, said out loud.
      def remove_tools(surface, keys, selected:, root:, app_roots: [ root ])
        keys.each do |key|
          tool = AiTool.find(key)
          outcome = { removed: [], trimmed: [], kept: [], failed: [] }

          app_roots.each do |app_root|
            Cleanup.remove(tools: [ key ], keeping: selected.map(&:to_sym), root: app_root).each do |bucket, paths|
              outcome[bucket].concat(paths.map { |path| shown(surface, File.join(app_root.to_s, path), root) })
            end
          end
          outcome[:removed].each { |path| surface.say "  Removed #{path}", :ok }
          outcome[:trimmed].each { |path| surface.say "  Removed the generated section from #{path}", :ok }
          outcome[:kept].each { |path| surface.say "  Kept #{path} (nothing in it was generated by rails-ai-context)", :muted }
          outcome[:failed].each { |path| surface.say "Could not remove #{path} - check its permissions", :warn }
          shared = say_shared(surface, tool, selected, root, app_roots)

          # Merge-safe MCP config cleanup - removes only the rails-ai-context entries
          left = []
          cleaned = [ root, *app_roots ].map(&:to_s).uniq.sum(0) do |dir|
            paths = RailsAiContext::McpConfigGenerator.remove(
              tools: [ key ], output_dir: dir,
              warn: lambda { |path, reason|
                left << path
                surface.say "Could not update #{shown(surface, path, root)}: #{reason}", :warn
              }
            )
            say_mcp_removed(surface, paths, base: dir, root: root)
            paths.size
          end

          gone = outcome[:removed].any? || outcome[:trimmed].any? || cleaned.positive?
          done = gone && outcome[:failed].empty? && left.empty? && !shared
          surface.say "  #{tool.name} files removed", :ok if tool && done
        end
      end

      # A file the dropped tool shares with one still selected (OpenCode's
      # AGENTS.md is Codex CLI's too) is kept, and saying nothing about it
      # read as though the cleanup had skipped the tool.
      #
      # @return [Boolean] whether anything was kept
      def say_shared(surface, tool, selected, root, app_roots)
        return false unless tool

        users = selected.filter_map { |key| AiTool.find(key) }.reject { |other| other.key == tool.key }
        paths = tool.context_paths & users.flat_map(&:context_paths)
        present = app_roots.flat_map do |app_root|
          paths.map { |path| File.join(app_root.to_s, path) }.select { |full| File.exist?(full) }
            .map { |full| shown(surface, full, root) }
        end
        return false if present.empty?

        names = users.select { |other| (other.context_paths & paths).any? }.map(&:name)
        surface.say "  Kept #{present.join(', ')} - #{names.join(' and ')} #{names.one? ? 'uses' : 'use'} " \
                    "#{present.one? ? 'it' : 'them'} too", :muted
        true
      end

      # CLI mode starts no MCP server, yet a config still holding the gem's
      # entry goes on starting one. Offered for removal the way a dropped
      # tool's files are, asked before anything is written.
      #
      # @return [Array<Symbol>] the tools whose configs are to lose the entry
      def ask_mcp_removal(surface, root:)
        held = AiTool.all.select do |tool|
          path = File.join(root.to_s, tool.mcp_config[:path])
          File.file?(path) && File.binread(path).include?(RailsAiContext::McpConfigGenerator::SERVER_NAME)
        end
        return [] if held.empty?

        surface.say ""
        surface.say "CLI mode starts no MCP server, but these configs still start rails-ai-context:", :emph
        held.each { |tool| surface.say "  #{shown(surface, File.join(root.to_s, tool.mcp_config[:path]), root)}" }
        surface.say ""
        input = surface.ask("Remove rails-ai-context from them? (y/N)").to_s.strip.downcase
        %w[y yes].include?(input) ? held.map(&:key) : []
      end

      def remove_mcp_entries(surface, tools, root:)
        return if tools.empty?

        paths = RailsAiContext::McpConfigGenerator.remove(
          tools: tools, output_dir: root.to_s,
          warn: ->(path, reason) { surface.say "Could not update #{shown(surface, path, root)}: #{reason}", :warn }
        )
        say_mcp_removed(surface, paths, base: root, root: root)
      end

      # A config the removal emptied is deleted whole, and is named as gone:
      # "removed the entry" over a file that no longer exists read like a
      # bug. The tool's directory goes with it when nothing else is in it.
      def say_mcp_removed(surface, paths, base:, root:)
        paths.each do |path|
          if File.exist?(path)
            surface.say "  Removed rails-ai-context from #{shown(surface, path, root)}", :ok
          else
            surface.say "  Removed #{shown(surface, path, root)} (rails-ai-context was its only server)", :ok
            prune_emptied(surface, File.dirname(path), base: base, root: root)
          end
        end
      end

      # The AI tools keep their files in dot-directories (.cursor/, .codex/,
      # .vscode/). One the cleanup emptied goes; one that holds anything
      # else stays, and no directory outside them is ever removed.
      def prune_emptied(surface, dir, base:, root:)
        base = base.to_s.delete_suffix("/")
        while dir.start_with?("#{base}/") && relative_to(dir, base).start_with?(".") && Dir.exist?(dir) &&
              !File.symlink?(dir) && Dir.empty?(dir)
          Dir.rmdir(dir)
          surface.say "  Removed #{shown(surface, "#{dir}/", root)}", :ok
          dir = File.dirname(dir)
        end
      rescue SystemCallError
        nil
      end

      # `context_files: false` never produces a .ai-context.json, so there is
      # nothing to ignore.
      def mark_gitignore(surface, root:, context_files: true)
        gitignore = File.join(root.to_s, ".gitignore")
        return unless File.exist?(gitignore)

        content = File.read(gitignore)
        lines = []
        if context_files && !content.include?(".ai-context.json")
          lines << "" << "# rails-ai-context (JSON cache - markdown files should be committed)" << ".ai-context.json"
        end
        unless content.include?(".codex/config.toml")
          lines << "" << "# rails-ai-context (embeds this machine's Ruby PATH/GEM_HOME - do not share)" << ".codex/config.toml"
        end
        return if lines.empty?

        File.open(gitignore, "a") { |f| lines.each { |line| f.puts line } }
        surface.say "Updated #{shown(surface, gitignore, root)}", :ok
      rescue SystemCallError, IOError => e
        RailsAiContext.log_warn "[rails-ai-context] could not write .gitignore: #{e.message}"
        surface.say "Could not update #{shown(surface, gitignore, root)} - add .ai-context.json and .codex/config.toml by hand", :warn
      end

      # Whether a commit would leave the Codex config out, which it must: it
      # holds this machine's PATH and GEM_HOME. Git answers, since the line
      # can sit in any .gitignore or in info/exclude; outside a repository
      # the app's .gitignore does.
      def codex_config_ignored?(root)
        _out, status = Open3.capture2e("git", "check-ignore", "-q", "--", ".codex/config.toml", chdir: root.to_s)
        return status.exitstatus.zero? if [ 0, 1 ].include?(status.exitstatus)

        gitignore = File.join(root.to_s, ".gitignore")
        File.exist?(gitignore) && File.read(gitignore).include?(".codex/config.toml")
      rescue SystemCallError
        false
      end

      # The selected tools whose MCP config a context run keeps up to date in
      # the app: every one, but for one a workspace's config above already
      # serves. The workspace set that one up, and a config of the app's own
      # beside it would start a second server for the same app.
      def own_config_tools(tools, root:)
        Array(tools).reject do |tool|
          config = AiTool.find(tool)&.mcp_config or next true
          serving = RailsAiContext::McpConfigGenerator.serving_config(root.to_s, tool)
          serving && serving != File.join(root.to_s, config[:path])
        end
      end

      # `standalone: nil` lets the generator detect the install mode from
      # Gemfile.lock, so every entry writes the same command form for the
      # same app (no config ping-pong). `servers:` replaces the app's own
      # entry with a workspace's, one per app.
      def write_mcp_configs(surface, tools:, tool_mode:, root:, standalone: nil, servers: nil)
        generator = RailsAiContext::McpConfigGenerator.new(
          tools: tools, output_dir: root.to_s, tool_mode: tool_mode, standalone: standalone, servers: servers
        )
        result = generator.call
        result[:written].each { |f| surface.say "Created/Updated #{shown(surface, f, root)}", :ok }
        result[:skipped].each { |f| surface.say "#{shown(surface, f, root)} unchanged - skipped", :muted }
        result[:notes]&.each { |f, note| surface.say "  #{shown(surface, f, root)}: #{note}", :muted }
        result[:failed].each do |f|
          surface.say "Could not write #{shown(surface, f, root)} - that tool will not auto-discover the MCP server", :warn
          surface.say result[:reasons][f], :warn if result[:reasons]&.[](f)
        end
        surface.say "Skipped MCP config files (CLI-only mode)", :muted if tool_mode == :cli
        result
      end

      # A path as the person running the install reads it: named from the
      # root, or from where they stand when that is outside it
      # (Surface#place). A directory keeps its trailing slash.
      def shown(surface, path, root)
        relative = relative_to(path, root)
        relative = "#{relative}/" if path.to_s.end_with?("/")
        place = surface.respond_to?(:place) ? surface.place : nil
        place ? File.join(place, relative) : relative
      end

      def relative_to(path, root)
        Pathname.new(path).relative_path_from(Pathname.new(root.to_s)).to_s
      rescue StandardError
        File.basename(path.to_s)
      end
    end
  end
end
