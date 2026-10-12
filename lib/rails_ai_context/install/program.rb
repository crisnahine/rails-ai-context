# frozen_string_literal: true

# Stdlib only: the standalone binary loads this before the gem entry, so it
# must stand alone the way the other install files do.
require "open3"
require "pathname"

module RailsAiContext
  module Install
    # The install program: which tools and which setup (asked, or given as
    # flags), what to clean up, what lands in .gitignore and which MCP configs
    # get written. Uninstall builds on its removals. Three
    # entry points ran a full copy each (~470 lines), and the copies drifted
    # where the eye cannot check - two labels for one mode, a menu that
    # showed file lists in two entries and bare names in the third.
    #
    # Entries supply a surface - say(text, level) and ask(prompt) - and keep
    # only their own voice (Thor colours, $stderr, puts) and their closing
    # instructions, which genuinely differ per invocation form.
    module Program
      module_function

      # The tools named on the command line: `--tools claude,cursor` or
      # `--tools all`. Names only, never menu numbers, which would read as
      # other tools once one is added.
      #
      # @return [Array<Symbol>, nil] in the menu's order; nil when the flag
      #   was not given
      # @raise [ArgumentError] when it names nothing, or names no tool
      def tools_flag(value)
        return nil if value.nil?

        names = value.to_s.downcase.split(/[\s,]+/).reject(&:empty?)
        accepted = "#{AiTool.keys.join(', ')} or all"
        # Thor hands a string option given no value its own name.
        if names.empty? || names == [ "tools" ]
          raise ArgumentError, "--tools needs a value: #{accepted}, comma-separated"
        end

        unknown = names.reject { |name| name == "all" || AiTool.find(name) }
        if unknown.any?
          raise ArgumentError, "#{unknown.map(&:inspect).join(', ')} #{unknown.one? ? 'is' : 'are'} not an AI tool. " \
                               "--tools takes #{accepted}, comma-separated"
        end

        return AiTool.keys if names.include?("all")

        AiTool.keys & names.map(&:to_sym)
      end

      # Every answer the command line gave, read before anything is asked or
      # written; nil where a flag was not given.
      #
      # @return [Hash] tools: (tools_flag), setup: (setup_flag)
      # @raise [ArgumentError] from either
      def given_answers(tools:, cli:, mcp_only:, mcp: false)
        { tools: tools_flag(tools), setup: setup_flag(cli: cli, mcp_only: mcp_only, mcp: mcp) }
      end

      # The setup question answered on the command line.
      #
      # @return [Setup, nil] nil when no flag was given
      # @raise [ArgumentError] when more than one was
      def setup_flag(cli:, mcp_only:, mcp: false)
        given = { mcp: mcp, cli: cli, mcp_only: mcp_only }.select { |_, on| on }.keys
        raise ArgumentError, "--mcp, --cli and --mcp-only are three different setups - pass one of them" if given.size > 1

        given.first && setup_for(given.first)
      end

      # @param surface [#say, #ask] ask returns the user's line, nil on EOF
      # @param current [Array<Symbol>, nil] what an earlier run recorded,
      #   shown above the question so a re-run starts from it
      # @param given [Array<Symbol>, nil] the answer from the command line
      #   (tools_flag), which skips the question
      # @return [Array<Symbol>] never empty; every tool when nothing usable
      #   was entered, and an answer that named no tool says so.
      def select_ai_tools(surface, current: nil, given: nil)
        tools = AiTool.all
        return say_selected(surface, given) if given

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

        prompt = "Enter numbers separated by commas (e.g. 1,2) or 'a' for all"
        prompt += chosen.any? ? " (default: keep the current selection):" : " (default: all):"
        input = surface.ask(prompt).to_s.strip.downcase

        selected = if input == "a" || input == "all"
          tools.map(&:key)
        else
          by_number = tools.to_h { |t| [ t.number, t.key ] }
          input.split(/[\s,]+/).filter_map { |n| by_number[n] }
        end

        # An empty answer takes the default: what a re-run had, else every
        # tool, and the Selected line below says which. Only an answer that
        # named nothing usable gets a line of its own.
        if selected.empty?
          fallback = chosen.any? ? "keeping the current selection" : "selecting all"
          surface.say "#{input.inspect} names no tool - #{fallback}.", :emph unless input.empty?
          selected = chosen.any? ? chosen.map(&:key) : tools.map(&:key)
        end

        say_selected(surface, selected)
      end

      def say_selected(surface, selected)
        names = AiTool.all.select { |t| selected.include?(t.key) }.map(&:name)
        surface.say "Selected: #{names.join(', ')}", :ok
        selected
      end

      # What this install writes. Answers 1 and 2 keep the meaning they have
      # always had, so anything piping input into the installer still works.
      Setup = Struct.new(:tool_mode, :context_files)

      # `flag` is the option that names the choice: --mcp, --cli, --mcp-only.
      SetupChoice = Struct.new(:flag, :label, :note, :setup)

      # The menu, in the order its numbers name.
      SETUP_CHOICES = [
        SetupChoice.new(:mcp, "MCP config + context files", "(default)", Setup.new(:mcp, true).freeze),
        SetupChoice.new(:cli, "Context files only", "(CLI mode, no MCP server)", Setup.new(:cli, true).freeze),
        SetupChoice.new(:mcp_only, "MCP config only", "(writes no CLAUDE.md, AGENTS.md or rules files)",
                        Setup.new(:mcp, false).freeze)
      ].freeze

      def setup_for(flag)
        SETUP_CHOICES.find { |choice| choice.flag == flag }.setup
      end

      # The setup the app recorded, nil when it recorded none.
      def recorded_setup(root:)
        tool_mode = SelectionRecord.tool_mode(root: root)
        context_files = SelectionRecord.context_files(root: root)
        return nil if tool_mode.nil? && context_files.nil?

        setup_for(flag_for(Setup.new(tool_mode, context_files != false)))
      end

      # @param given [Setup, nil] the answer from the command line
      #   (setup_flag), which skips the question
      # @param current [Setup, nil] what an earlier run recorded, the default
      #   an empty answer keeps
      def select_setup(surface, given: nil, current: nil)
        if given
          surface.say "Selected: #{setup_label(given)}", :ok
          return given
        end

        surface.say ""
        surface.say "What should rails-ai-context write?", :emph
        surface.say ""
        SETUP_CHOICES.each.with_index(1) do |choice, number|
          surface.say "  #{number}. #{choice.label.ljust(29)}#{choice.note}"
        end
        surface.say ""
        surface.say "Currently: #{setup_label(current)}" if current
        default = current ? setup_number(current) : 1

        input = surface.ask("Enter number (default: #{default}):").to_s.strip
        number = (1..SETUP_CHOICES.size).cover?(input.to_i) && input.match?(/\A\d+\z/) ? input.to_i : default
        setup = SETUP_CHOICES[number - 1].setup
        surface.say "Selected: #{setup_label(setup)}", :ok
        setup
      end

      # The answer in the words the question offered it.
      def setup_label(setup)
        choice = SETUP_CHOICES[setup_number(setup) - 1]
        choice.flag == :mcp ? choice.label : "#{choice.label} #{choice.note}"
      end

      # The menu number the setup is offered under.
      def setup_number(setup)
        SETUP_CHOICES.index { |choice| choice.flag == flag_for(setup) } + 1
      end

      # The choice a setup is. Context files off is the MCP-only one whatever
      # the tool mode says.
      def flag_for(setup)
        return :mcp_only unless setup.context_files

        setup.tool_mode == :cli ? :cli : :mcp
      end

      # Offers to remove what a re-run dropped from the selection, and
      # removes it. A file shared with a tool whose files stay (AGENTS.md)
      # stays.
      #
      # `app_roots:` names where the context files live when that is not
      # `root`: a workspace keeps them in each app and its MCP entries in
      # itself. Paths are reported relative to `root` either way.
      def cleanup_removed_tools(surface, previous:, selected:, root:, app_roots: [ root ], prune: false)
        to_remove = ask_removed_tools(surface, previous: previous, selected: selected, prune: prune)
        remove_tools(surface, to_remove, selected: selected, previous: previous, root: root, app_roots: app_roots)
      end

      # The question half of the cleanup, for an entry that asks everything
      # before it writes anything. `prune: true` (--prune) answers yes.
      #
      # @return [Array<Symbol>] the dropped tools whose files are to go
      def ask_removed_tools(surface, previous:, selected:, prune: false)
        removed = Array(previous).map(&:to_sym) - selected.map(&:to_sym)
        return [] if removed.empty?

        surface.say ""
        surface.say "These AI tools were removed from your selection:", :emph
        removed.each_with_index do |key, idx|
          tool = AiTool.find(key)
          surface.say "  #{idx + 1}. #{tool.name} (#{tool.files})" if tool
        end
        return removed if prune

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
      # every file it shares with a tool whose files stay - one still
      # selected, or one dropped whose files the answer kept - stays, said
      # out loud.
      #
      # `http_entries: true` also takes an HTTP entry under the gem's name,
      # which only the gem's mounted endpoint answers: uninstall's case.
      #
      # @return [Boolean] whether anything was removed
      def remove_tools(surface, keys, selected:, root:, app_roots: [ root ], previous: selected, http_entries: false)
        keeping = (selected.map(&:to_sym) + (Array(previous).map(&:to_sym) - selected.map(&:to_sym) - keys.map(&:to_sym))).uniq
        keys.count do |key|
          tool = AiTool.find(key)
          outcome = { removed: [], trimmed: [], kept: [], failed: [] }

          app_roots.each do |app_root|
            Cleanup.remove(tools: [ key ], keeping: keeping, root: app_root).each do |bucket, paths|
              outcome[bucket].concat(paths.map { |path| shown(surface, File.join(app_root.to_s, path), root) })
            end
          end
          outcome[:removed].each { |path| surface.say "  Removed #{path}", :ok }
          outcome[:trimmed].each { |path| surface.say "  Removed the generated section from #{path}", :ok }
          outcome[:kept].each { |path| surface.say "  Kept #{path} (nothing in it was generated by rails-ai-context)", :muted }
          outcome[:failed].each { |path| surface.say "Could not remove #{path} - check its permissions", :warn }
          shared = say_shared(surface, tool, keeping, root, app_roots)

          # Merge-safe MCP config cleanup - removes only the rails-ai-context entries
          left = []
          cleaned = [ root, *app_roots ].map(&:to_s).uniq.sum(0) do |dir|
            paths = RailsAiContext::McpConfigGenerator.remove(
              tools: [ key ], output_dir: dir, http_entries: http_entries,
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
          gone
        end.positive?
      end

      # A file the dropped tool shares with one whose files stay (OpenCode's
      # AGENTS.md is Codex CLI's too) is kept, and saying nothing about it
      # read as though the cleanup had skipped the tool.
      #
      # @return [Boolean] whether anything was kept
      def say_shared(surface, tool, keeping, root, app_roots)
        return false unless tool

        users = keeping.filter_map { |key| AiTool.find(key) }.reject { |other| other.key == tool.key }
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
      # `prune: true` (--prune) answers yes.
      #
      # @return [Array<Symbol>] the tools whose configs are to lose the entry
      def ask_mcp_removal(surface, root:, prune: false)
        held = AiTool.all.select do |tool|
          path = File.join(root.to_s, tool.mcp_config[:path])
          File.file?(path) && File.binread(path).include?(RailsAiContext::McpConfigGenerator::SERVER_NAME)
        end
        return [] if held.empty?

        surface.say ""
        surface.say "CLI mode starts no MCP server, but these configs still start rails-ai-context:", :emph
        held.each { |tool| surface.say "  #{shown(surface, File.join(root.to_s, tool.mcp_config[:path]), root)}" }
        return held.map(&:key) if prune

        surface.say ""
        yes?(surface, "Remove rails-ai-context from them? (y/N)") ? held.map(&:key) : []
      end

      # The MCP-only setup writes no context files, yet the ones an earlier
      # setup generated stay, no longer refreshed. Offered for removal the
      # way CLI mode offers the MCP entries; `prune: true` answers yes.
      #
      # @return [Boolean] whether remove_context_files is to run
      def ask_context_removal(surface, tools:, root:, app_roots: [ root ], prune: false)
        stale = app_roots.to_h do |app_root|
          paths = Cleanup.generated(tools: tools, root: app_root).values.flatten.uniq
          paths << JSON_CACHE if File.file?(File.join(app_root.to_s, JSON_CACHE))
          [ app_root, paths ]
        end
        return false if stale.values.all?(&:empty?)

        surface.say ""
        surface.say "The MCP-only setup writes no context files, but these generated ones would go stale:", :emph
        stale.each do |app_root, paths|
          paths.each { |path| surface.say "  #{shown(surface, File.join(app_root.to_s, path), root)}" }
        end
        return true if prune

        surface.say ""
        yes?(surface, "Remove the generated parts? Lines you wrote stay. (y/N)")
      end

      def yes?(surface, prompt)
        %w[y yes].include?(surface.ask(prompt).to_s.strip.downcase)
      end

      def remove_context_files(surface, tools, root:, app_roots: [ root ])
        app_roots.each do |app_root|
          named = ->(path) { shown(surface, File.join(app_root.to_s, path), root) }
          outcome = Cleanup.remove(tools: tools, keeping: [], root: app_root)
          json = File.join(app_root.to_s, JSON_CACHE)
          if File.file?(json)
            File.delete(json)
            outcome[:removed] << JSON_CACHE
          end
          outcome[:removed].each { |path| surface.say "  Removed #{named.call(path)}", :ok }
          outcome[:trimmed].each { |path| surface.say "  Removed the generated section from #{named.call(path)}", :ok }
          outcome[:failed].each { |path| surface.say "Could not remove #{named.call(path)}", :warn }
        rescue SystemCallError => e
          surface.say "Could not remove the context files: #{e.message}", :warn
        end
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

      # The JSON copy of the context, regenerated from the app: never committed.
      JSON_CACHE = ".ai-context.json"

      # Each path mark_gitignore appends to .gitignore, with the comment above
      # it. Uninstall takes out exactly these lines.
      GITIGNORE_NOTES = {
        JSON_CACHE => "# rails-ai-context (JSON cache - markdown files should be committed)",
        ".codex/config.toml" => "# rails-ai-context (embeds this machine's Ruby PATH/GEM_HOME - do not share)"
      }.freeze

      # `context_files: false` never produces a .ai-context.json, so there is
      # nothing to ignore.
      def mark_gitignore(surface, root:, context_files: true)
        gitignore = File.join(root.to_s, ".gitignore")
        return unless File.exist?(gitignore)

        content = File.read(gitignore)
        lines = []
        GITIGNORE_NOTES.each do |path, note|
          next if content.include?(path) || (path == JSON_CACHE && !context_files) || excluded_privately?(root, path)

          lines << "" << note << path
        end
        return if lines.empty?

        File.open(gitignore, "a") { |f| lines.each { |line| f.puts line } }
        surface.say "Updated #{shown(surface, gitignore, root)}", :ok
      rescue SystemCallError, IOError => e
        RailsAiContext.log_warn "[rails-ai-context] could not write .gitignore: #{e.message}"
        surface.say "Could not update #{shown(surface, gitignore, root)} - add .ai-context.json and .codex/config.toml by hand", :warn
      end

      # What the user does next in each selected AI tool for its MCP server
      # to start, one line per tool, in the menu's order.
      def next_steps(tools)
        chosen = Array(tools).map(&:to_sym)
        AiTool.all.select { |tool| chosen.include?(tool.key) }.map { |tool| "#{tool.name}: #{tool.next_step}" }
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

      # Whether this repository's own exclude file (.git/info/exclude, which
      # git never commits) leaves the path out: a private setup's choice. A
      # global excludes file does not count, since teammates lack it.
      def excluded_privately?(root, path)
        out, status = Open3.capture2e("git", "check-ignore", "-v", "--", path, chdir: root.to_s)
        status.success? && out.split(":", 2).first.to_s.end_with?("info/exclude")
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
        result[:skipped].each { |f| surface.say "#{shown(surface, f, root)} (unchanged)", :muted }
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
