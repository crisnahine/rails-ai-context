# frozen_string_literal: true

require "json"

module RailsAiContext
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Install rails-ai-context: creates initializer, MCP config, and generates initial context files."

      AI_TOOLS = {
        "1" => { key: :claude,   name: "Claude Code",     files: "CLAUDE.md + .claude/rules/",                        format: :claude },
        "2" => { key: :cursor,   name: "Cursor",          files: ".cursor/rules/",                                     format: :cursor },
        "3" => { key: :copilot,  name: "GitHub Copilot",  files: ".github/copilot-instructions.md + .github/instructions/", format: :copilot },
        "4" => { key: :opencode, name: "OpenCode",        files: "AGENTS.md",                                          format: :opencode },
        "5" => { key: :codex,   name: "Codex CLI",       files: "AGENTS.md + .codex/config.toml",                     format: :codex }
      }.freeze

      # Files/dirs generated per AI tool format — used for cleanup on tool removal.
      # MCP config files are NOT listed here — they use merge-safe removal via
      # McpConfigGenerator.remove to preserve other servers' entries.
      FORMAT_PATHS = {
        claude:   %w[CLAUDE.md .claude/rules],
        cursor:   %w[.cursor/rules],
        copilot:  %w[.github/copilot-instructions.md .github/instructions],
        opencode: %w[AGENTS.md app/models/AGENTS.md app/controllers/AGENTS.md],
        codex:    %w[AGENTS.md app/models/AGENTS.md app/controllers/AGENTS.md]
      }.freeze

      def select_ai_tools
        say ""
        say "Which AI tools do you use? (select all that apply)", :yellow
        say ""
        AI_TOOLS.each do |num, info|
          say "  #{num}. #{info[:name].ljust(16)} → #{info[:files]}"
        end
        say "  a. All of the above"
        say ""

        input = ask("Enter numbers separated by commas (e.g. 1,2) or 'a' for all:").strip.downcase

        @selected_formats = if input == "a" || input == "all"
          AI_TOOLS.values.map { |t| t[:format] }
        else
          nums = input.split(/[\s,]+/)
          nums.filter_map { |n| AI_TOOLS[n]&.dig(:format) }
        end

        if @selected_formats.empty?
          say "No tools selected — defaulting to all.", :yellow
          @selected_formats = AI_TOOLS.values.map { |t| t[:format] }
        end

        selected_names = AI_TOOLS.values.select { |t| @selected_formats.include?(t[:format]) }.map { |t| t[:name] }
        say ""
        say "Selected: #{selected_names.join(', ')}", :green
      end

      def cleanup_removed_tools
        @previous_formats = read_previous_ai_tools
        return unless @previous_formats&.any?

        removed = @previous_formats - @selected_formats
        return if removed.empty?

        say ""
        say "These AI tools were removed from your selection:", :yellow
        removed.each_with_index do |fmt, idx|
          tool = AI_TOOLS.values.find { |t| t[:format] == fmt }
          say "  #{idx + 1}. #{tool[:name]} (#{tool[:files]})" if tool
        end
        say ""

        say "Remove their generated files?", :yellow
        say "  y — remove all listed above"
        say "  n — keep all (default)"
        say "  1,2 — remove only specific ones by number"
        say ""

        input = ask("Enter choice:").strip.downcase
        return if input.empty? || input == "n" || input == "no"

        to_remove = if input == "y" || input == "yes" || input == "a"
          removed
        else
          nums = input.split(/[\s,]+/).filter_map { |n| n.to_i - 1 }
          nums.filter_map { |i| removed[i] if i >= 0 && i < removed.size }
        end

        return if to_remove.empty?

        # Collect paths still needed by remaining tools to avoid deleting shared files
        kept_paths = @selected_formats.flat_map { |f| FORMAT_PATHS[f] || [] }.to_set

        to_remove.each do |fmt|
          tool = AI_TOOLS.values.find { |t| t[:format] == fmt }

          # Remove context files (skip if another selected tool still needs them)
          paths = FORMAT_PATHS[fmt] || []
          paths.each do |rel_path|
            next if kept_paths.include?(rel_path)

            full = Rails.root.join(rel_path)
            if File.directory?(full)
              FileUtils.rm_rf(full)
              say "  Removed #{rel_path}/", :red
            elsif File.exist?(full)
              FileUtils.rm_f(full)
              say "  Removed #{rel_path}", :red
            end
          end

          # Merge-safe MCP config cleanup — removes only the rails-ai-context entry
          cleaned = RailsAiContext::McpConfigGenerator.remove(tools: [ fmt ], output_dir: Rails.root.to_s)
          cleaned.each { |f| say "  Removed MCP entry from #{Pathname.new(f).relative_path_from(Rails.root)}", :red }

          say "  ✓ #{tool[:name]} files removed", :green if tool
        end
      end

      def select_tool_mode
        say ""
        say "Do you also want MCP server support?", :yellow
        say ""
        say "  1. Yes — MCP primary + CLI fallback (generates per-tool MCP config files)"
        say "  2. No  — CLI only (no server needed)"
        say ""

        input = ask("Enter number (default: 1):").strip

        @tool_mode = case input
        when "2" then :cli
        else :mcp
        end

        mode_label = @tool_mode == :mcp ? "MCP + CLI fallback" : "CLI only"
        say "Selected: #{mode_label}", :green
      end

      def create_mcp_config
        generator = RailsAiContext::McpConfigGenerator.new(
          tools: @selected_formats,
          output_dir: Rails.root.to_s,
          standalone: false,
          tool_mode: @tool_mode
        )
        result = generator.call
        result[:written].each do |f|
          rel = Pathname.new(f).relative_path_from(Rails.root)
          say "Created/Updated #{rel}", :green
        end
        result[:skipped].each do |f|
          rel = Pathname.new(f).relative_path_from(Rails.root)
          say "#{rel} unchanged — skipped", :yellow
        end
        if @tool_mode == :cli
          say "Skipped MCP config files (CLI-only mode)", :yellow
        end
      end

      # All config sections with their marker comment and content.
      # Each section is identified by its marker (e.g., "── AI Tools ──").
      # On re-install, only sections NOT already present are appended.
      CONFIG_SECTIONS = {
        "AI Tools" => <<~SECTION,
            # ── AI Tools ──────────────────────────────────────────────────────
            # Which AI tools to generate context files for (selected during install)
            # Run `rails generate rails_ai_context:install` to change selection
            # config.ai_tools = %i[claude cursor copilot opencode codex]  # default: all

            # Tool invocation mode:
            #   :mcp — MCP primary + CLI fallback (default, requires `rails ai:serve`)
            #   :cli — CLI only (no MCP server needed, uses `rails 'ai:tool[NAME]'`)
            # config.tool_mode = :mcp
        SECTION
        "Introspection" => <<~SECTION,
            # ── Introspection ─────────────────────────────────────────────────
            # Introspector preset:
            #   :full     — all #{RailsAiContext::Configuration::PRESETS[:full].size} introspectors (default)
            #   :standard — #{RailsAiContext::Configuration::PRESETS[:standard].size} core introspectors (schema, models, routes, jobs, gems,
            #               conventions, controllers, tests, migrations, stimulus,
            #               view_templates, config, components)
            # config.preset = :full

            # Context mode: :compact (default, ≤150 lines) or :full (dumps everything)
            # config.context_mode = :compact

            # Max lines for CLAUDE.md in compact mode
            # config.claude_max_lines = 150

            # Whether to generate root files (CLAUDE.md, AGENTS.md, etc.)
            # Set false to only generate split rules (.claude/rules/, .cursor/rules/, etc.)
            # config.generate_root_files = true

            # Anti-Hallucination Protocol: 6-rule verification section embedded in every
            # generated context file. Forces AI to verify facts before writing code.
            # Default: true. Set false to skip the protocol entirely.
            # config.anti_hallucination_rules = true
        SECTION
        "Models & Filtering" => <<~SECTION,
            # ── Models & Filtering ────────────────────────────────────────────
            # Models to exclude from introspection
            # config.excluded_models += %w[AdminUser InternalThing]

            # Framework association names hidden from model output
            # (ActiveStorage, ActionText, ActionMailbox, Noticed associations are excluded by default)
            # config.excluded_association_names += %w[my_custom_framework_assoc]

            # Controllers to exclude from listings
            # config.excluded_controllers += %w[Admin::BaseController]

            # Route prefixes to hide with app_only filter
            # config.excluded_route_prefixes += %w[sidekiq/]
        SECTION
        "MCP Server" => <<~SECTION,
            # ── MCP Server ────────────────────────────────────────────────────
            # Cache TTL in seconds for introspection data
            # config.cache_ttl = 60

            # Max characters for any single tool response (safety net)
            # config.max_tool_response_chars = 200_000

            # Live reload: auto-invalidate MCP tool caches on file changes
            #   :auto — enable if `listen` gem is available (default)
            #   true  — enable, raise if `listen` gem is missing
            #   false — disable entirely
            # config.live_reload = :auto

            # Auto-mount HTTP MCP endpoint (for HTTP transport)
            # config.auto_mount = false
            # config.http_path = "/mcp"
            # config.http_port = 6029
        SECTION
        "File Size Limits" => <<~SECTION,
            # ── File Size Limits ──────────────────────────────────────────────
            # Increase for larger projects
            # config.max_file_size = 5_000_000         # Per-file read (5MB)
            # config.max_test_file_size = 1_000_000    # Test file read (1MB)
            # config.max_schema_file_size = 10_000_000 # schema.rb parse (10MB)
            # config.max_view_total_size = 10_000_000  # Aggregated view content (10MB)
            # config.max_view_file_size = 1_000_000    # Per-view file (1MB)
            # config.max_search_results = 200          # Max search results per call
            # config.max_validate_files = 50           # Max files per validate call
        SECTION
        "Extensibility" => <<~SECTION,
            # ── Extensibility ─────────────────────────────────────────────────
            # Register additional MCP tool classes alongside the #{RailsAiContext::Server.builtin_tools.size} built-in tools
            # config.custom_tools = [MyApp::CustomTool]

            # Exclude specific built-in tools by name
            # config.skip_tools = %w[rails_security_scan]
        SECTION
        "Security" => <<~SECTION,
            # ── Security ──────────────────────────────────────────────────────
            # Paths excluded from code search
            # config.excluded_paths += %w[vendor/cache]

            # File patterns blocked from search and read tools
            # config.sensitive_patterns += %w[config/secrets.yml]
        SECTION
        "Search" => <<~SECTION,
            # ── Search ────────────────────────────────────────────────────────
            # File extensions for fallback search (when ripgrep unavailable)
            # config.search_extensions = %w[rb js erb yml yaml json ts tsx vue svelte haml slim]

            # Where to look for concern source files
            # config.concern_paths = %w[app/models/concerns app/controllers/concerns]
        SECTION
        "Frontend" => <<~SECTION
            # ── Frontend Framework Detection ─────────────────────────────────
            # Auto-detected from package.json, config/vite.json, etc. Override only if needed.
            # config.frontend_paths = ["app/frontend", "../web-client"]
        SECTION
      }.freeze

      def create_initializer
        initializer_path = "config/initializers/rails_ai_context.rb"
        full_path = Rails.root.join(initializer_path)

        if File.exist?(full_path)
          update_existing_initializer(full_path)
        else
          create_new_initializer(initializer_path)
        end
      end

      no_tasks do
      def create_new_initializer(path)
        # Always write uncommented so re-install can detect previous selection
        tools_line = "  config.ai_tools = %i[#{@selected_formats.join(' ')}]"

        tool_mode_line = if @tool_mode == :cli
          "  config.tool_mode = :cli    # CLI only (no MCP server needed)"
        else
          "  config.tool_mode = :mcp   # MCP primary + CLI fallback"
        end

        content = "# frozen_string_literal: true\n\nRailsAiContext.configure do |config|\n"

        # AI Tools section gets dynamic values from user selection
        content += <<~SECTION
            # ── AI Tools ──────────────────────────────────────────────────────
            # Which AI tools to generate context files for (selected during install)
            # Run `rails generate rails_ai_context:install` to change selection
          #{tools_line}

            # Tool invocation mode:
            #   :mcp — MCP primary + CLI fallback (default, requires `rails ai:serve`)
            #   :cli — CLI only (no MCP server needed, uses `rails 'ai:tool[NAME]'`)
          #{tool_mode_line}

        SECTION

        # All remaining sections use defaults (commented out)
        CONFIG_SECTIONS.each do |name, section_content|
          next if name == "AI Tools" # already added with dynamic values
          content += section_content + "\n"
        end

        content += "end\n"
        content, = ensure_initializer_guard(content)

        create_file path, content
        say "Created #{path} with all #{CONFIG_SECTIONS.size} config sections", :green
      end

      def update_existing_initializer(full_path)
        existing = File.read(full_path)
        changes = []

        # 1. Update ai_tools selection if user picked new tools
        existing, changed = update_config_line(existing, "config.ai_tools", build_ai_tools_line)
        changes << "ai_tools" if changed

        # 2. Update tool_mode if user picked a new mode
        existing, changed = update_config_line(existing, "config.tool_mode", build_tool_mode_line)
        changes << "tool_mode" if changed

        # 3. Add any missing config sections
        CONFIG_SECTIONS.each do |name, section_content|
          marker = "── #{name}"
          next if existing.include?(marker)

          insert_point = configure_block_end_index(existing)
          if insert_point
            existing = existing.insert(insert_point, "\n#{reindent_section_content(section_content, existing)}\n")
            changes << "section: #{name}"
          end
        end

        existing, changed = ensure_initializer_guard(existing)
        changes << "guard" if changed

        if changes.any?
          File.write(full_path, existing)
          say "Updated #{full_path.relative_path_from(Rails.root)}: #{changes.join(', ')}", :green
        else
          say "#{full_path.relative_path_from(Rails.root)} is up to date — no changes needed", :green
        end
      end

      # Replace or uncomment a config line. Returns [new_content, changed?]
      def update_config_line(content, key, new_line)
        # Match both commented and uncommented versions of this config key
        pattern = /^([ \t]*)#?\s*#{Regexp.escape(key)}\s*=.*$/
        if content.match?(pattern)
          updated = content.sub(pattern) do
            "#{Regexp.last_match(1)}#{new_line.lstrip}"
          end
          [ updated, updated != content ]
        else
          # Key not found at all — don't add (it's in a section that will be added)
          [ content, false ]
        end
      end

      def configure_block_end_index(content)
        end_positions = []
        content.to_enum(:scan, /^[ \t]*end\b/).each do
          end_positions << Regexp.last_match.begin(0)
        end
        return nil if end_positions.empty?

        if guarded_initializer?(content) && end_positions.size >= 2
          end_positions[-2]
        else
          end_positions[-1]
        end
      end

      def ensure_initializer_guard(content)
        return [ content, false ] if guarded_initializer?(content)

        header_match = content.match(/\A# frozen_string_literal: true\n(?:\n)?/)
        header = header_match ? "# frozen_string_literal: true\n\n" : ""
        body = header_match ? content.delete_prefix(header_match[0]) : content
        body = "#{body}\n" unless body.end_with?("\n")

        wrapped = "#{header}if defined?(RailsAiContext)\n#{indent_content(body)}end\n"
        [ wrapped, wrapped != content ]
      end

      def reindent_section_content(section_content, content)
        indent = configure_body_indent(content)
        section_content.lines.map do |line|
          next line if line == "\n"

          "#{indent}#{line.sub(/\A[ \t]{0,2}/, "")}"
        end.join
      end

      def configure_body_indent(content)
        match = content.match(/^([ \t]*)RailsAiContext\.configure do \|config\|$/)
        return "  " unless match

        "#{match[1]}  "
      end

      def guarded_initializer?(content)
        content.match?(/^[ \t]*if defined\?\(RailsAiContext\)$/)
      end

      def indent_content(content)
        content.lines.map { |line| line == "\n" ? line : "  #{line}" }.join
      end

      def build_ai_tools_line
        # Always write uncommented so re-install can detect previous selection
        "  config.ai_tools = %i[#{@selected_formats.join(' ')}]"
      end

      def build_tool_mode_line
        if @tool_mode == :cli
          "  config.tool_mode = :cli    # CLI only (no MCP server needed)"
        else
          "  config.tool_mode = :mcp   # MCP primary + CLI fallback"
        end
      end

      def read_previous_ai_tools
        init_path = Rails.root.join("config/initializers/rails_ai_context.rb")
        return nil unless File.exist?(init_path)

        content = File.read(init_path)
        match = content.match(/^\s*config\.ai_tools\s*=\s*%i\[([^\]]*)\]/)
        return nil unless match

        match[1].split.map(&:to_sym)
      rescue => e
        $stderr.puts "[rails-ai-context] read_previous_ai_tools failed: #{e.message}" if ENV["DEBUG"]
        nil
      end
      end # no_tasks

      def create_yaml_config
        yaml_path = Rails.root.join(".rails-ai-context.yml")
        content = {
          "ai_tools" => @selected_formats.map(&:to_s),
          "tool_mode" => @tool_mode.to_s
        }

        require "yaml"
        File.write(yaml_path, YAML.dump(content))
        say "Created .rails-ai-context.yml (standalone config)", :green
      end

      def add_to_gitignore
        gitignore = Rails.root.join(".gitignore")
        return unless File.exist?(gitignore)

        content = File.read(gitignore)
        append = []
        append << ".ai-context.json" unless content.include?(".ai-context.json")

        if append.any?
          File.open(gitignore, "a") do |f|
            f.puts ""
            f.puts "# rails-ai-context (JSON cache — markdown files should be committed)"
            append.each { |line| f.puts line }
          end
          say "Updated .gitignore", :green
        end
      end

      def generate_context_files
        say ""
        say "Generating AI context files...", :yellow

        unless Rails.application
          say "  Skipped (Rails app not fully loaded). Run `rails ai:context` after install.", :yellow
          return
        end

        require "rails_ai_context"

        # One-time v5.0.0 legacy UI-pattern files cleanup prompt
        RailsAiContext::LegacyCleanup.prompt_legacy_files(
          @selected_formats, root: Rails.root
        )

        @selected_formats.each do |fmt|
          begin
            result = RailsAiContext.generate_context(format: fmt)
            (result[:written] || []).each { |f| say "  ✅ #{f}", :green }
            (result[:skipped] || []).each { |f| say "  ⏭️  #{f} (unchanged)", :yellow }
          rescue => e
            say "  ❌ #{fmt}: #{e.message}", :red
          end
        end
      end

      def show_instructions
        say ""
        say "=" * 50, :cyan
        say " rails-ai-context installed!", :cyan
        say "=" * 50, :cyan
        say ""
        say "Your setup:", :yellow
        AI_TOOLS.each_value do |info|
          next unless @selected_formats.include?(info[:format])
          say "  ✅ #{info[:name].ljust(16)} → #{info[:files]}"
        end
        say ""
        say "Commands:", :yellow
        say "  rails ai:context         # Regenerate context files"
        tool_count = RailsAiContext::Server.builtin_tools.size
        say "  rails 'ai:tool[schema]'    # Run any of the #{tool_count} tools from CLI"
        if @tool_mode == :mcp
          say "  rails ai:serve           # Start MCP server (#{tool_count} live tools)"
        end
        say "  rails ai:doctor          # Check AI readiness"
        say "  rails ai:inspect         # Print introspection summary"
        say ""
        if @tool_mode == :mcp
          say "MCP auto-discovery:", :yellow
          say "  Each AI tool gets its own config file — auto-detected on project open."
          say "  No manual config needed."
        else
          say "CLI tools:", :yellow
          say "  AI agents can run `rails 'ai:tool[schema]' table=users` directly."
          say "  No MCP server needed — tools work from the terminal."
        end
        say ""
        say "To add more AI tools later:", :yellow
        say "  rails ai:context:cursor   # Generate for Cursor"
        say "  rails ai:context:copilot  # Generate for Copilot"
        say "  rails generate rails_ai_context:install  # Re-run to pick tools"
        say ""
        say "Standalone (no Gemfile needed):", :yellow
        say "  gem install rails-ai-context"
        say "  rails-ai-context init          # interactive setup"
        say "  rails-ai-context serve         # start MCP server"
        say ""
        say "Commit context files and MCP config files so your team benefits!", :green
      end
    end
  end
end
