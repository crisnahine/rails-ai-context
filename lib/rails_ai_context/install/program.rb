# frozen_string_literal: true

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
      # @return [Array<Symbol>] never empty; every tool when nothing usable
      #   was entered, stated out loud so --defaults and EOF read the same.
      def select_ai_tools(surface)
        tools = AiTool.all
        surface.say ""
        surface.say "Which AI tools do you use? (select all that apply)", :emph
        surface.say ""
        tools.each { |t| surface.say "  #{t.number}. #{t.name.ljust(16)} -> #{t.files}" }
        surface.say "  a. All of the above"
        surface.say ""

        input = surface.ask("Enter numbers separated by commas (e.g. 1,2) or 'a' for all:").to_s.strip.downcase

        selected = if input == "a" || input == "all"
          tools.map(&:key)
        else
          by_number = tools.to_h { |t| [ t.number, t.key ] }
          input.split(/[\s,]+/).filter_map { |n| by_number[n] }
        end

        if selected.empty?
          surface.say "No tools selected - defaulting to all.", :emph
          selected = tools.map(&:key)
        end

        names = tools.select { |t| selected.include?(t.key) }.map(&:name)
        surface.say "Selected: #{names.join(', ')}", :ok
        selected
      end

      def select_tool_mode(surface)
        surface.say ""
        surface.say "Do you also want MCP server support?", :emph
        surface.say ""
        surface.say "  1. Yes - MCP primary + CLI fallback (generates per-tool MCP config files)"
        surface.say "  2. No  - CLI only (no server needed)"
        surface.say ""

        input = surface.ask("Enter number (default: 1):").to_s.strip
        mode = input == "2" ? :cli : :mcp
        surface.say "Selected: #{mode == :mcp ? 'MCP + CLI fallback' : 'CLI only'}", :ok
        mode
      end

      # Offers to remove what a re-run dropped from the selection. `keeping:`
      # protects files the remaining tools share (AGENTS.md).
      def cleanup_removed_tools(surface, previous:, selected:, root:)
        removed = Array(previous).map(&:to_sym) - selected.map(&:to_sym)
        return if removed.empty?

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
        return if input.empty? || input == "n" || input == "no"

        to_remove = if %w[y yes a].include?(input)
          removed
        else
          nums = input.split(/[\s,]+/).filter_map { |n| n.to_i - 1 }
          nums.filter_map { |i| removed[i] if i >= 0 && i < removed.size }
        end
        return if to_remove.empty?

        to_remove.each do |key|
          tool = AiTool.find(key)

          removed_paths = Cleanup.remove(tools: [ key ], keeping: selected.map(&:to_sym), root: root)
          removed_paths.each { |path| surface.say "  Removed #{path}", :warn }

          # Merge-safe MCP config cleanup - removes only the rails-ai-context entry
          cleaned = RailsAiContext::McpConfigGenerator.remove(tools: [ key ], output_dir: root.to_s)
          cleaned.each { |f| surface.say "  Removed MCP entry from #{relative_to(f, root)}", :warn }

          surface.say "  #{tool.name} files removed", :ok if tool
        end
      end

      def mark_gitignore(surface, root:)
        gitignore = File.join(root.to_s, ".gitignore")
        return unless File.exist?(gitignore)

        content = File.read(gitignore)
        lines = []
        unless content.include?(".ai-context.json")
          lines << "" << "# rails-ai-context (JSON cache - markdown files should be committed)" << ".ai-context.json"
        end
        unless content.include?(".codex/config.toml")
          lines << "" << "# rails-ai-context (embeds this machine's Ruby PATH/GEM_HOME - do not share)" << ".codex/config.toml"
        end
        return if lines.empty?

        File.open(gitignore, "a") { |f| lines.each { |line| f.puts line } }
        surface.say "Updated .gitignore", :ok
      end

      # `standalone: nil` lets the generator detect the install mode from
      # Gemfile.lock, so every entry writes the same command form for the
      # same app (no config ping-pong).
      def write_mcp_configs(surface, tools:, tool_mode:, root:, standalone: nil)
        generator = RailsAiContext::McpConfigGenerator.new(
          tools: tools, output_dir: root.to_s, tool_mode: tool_mode, standalone: standalone
        )
        result = generator.call
        result[:written].each { |f| surface.say "Created/Updated #{relative_to(f, root)}", :ok }
        result[:skipped].each { |f| surface.say "#{relative_to(f, root)} unchanged - skipped", :muted }
        surface.say "Skipped MCP config files (CLI-only mode)", :muted if tool_mode == :cli
        result
      end

      def relative_to(path, root)
        Pathname.new(path).relative_path_from(Pathname.new(root.to_s)).to_s
      rescue StandardError
        File.basename(path.to_s)
      end
    end
  end
end
