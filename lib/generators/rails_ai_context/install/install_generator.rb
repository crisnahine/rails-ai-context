# frozen_string_literal: true

require "json"
require "thor/line_editor"

# Thor's interactive `ask` reads the line through Reline once the `readline`
# library is available, and Reline writes cursor control escape sequences
# (hide/show cursor, clear line) to support in-place editing - it does this
# even when neither end of the process is attached to a real terminal.
# Restrict it to genuine TTY sessions so piped or redirected runs (CI, `rails
# generate ... < /dev/null`, captured logs) get plain prompt text instead of
# raw escape codes; Thor already falls back to a plain, escape-free reader
# when this returns false.
class Thor
  module LineEditor
    class Readline
      def self.available?
        return false unless $stdin.tty? && $stdout.tty?

        begin
          require "readline"
        rescue LoadError
        end

        Object.const_defined?(:Readline)
      end
    end
  end
end

module RailsAiContext
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Install rails-ai-context: creates initializer, MCP config, and generates initial context files."

      class_option :defaults, type: :boolean, default: false,
        desc: "Skip all interactive prompts and use each prompt's documented default (for CI/non-interactive use)"

      BARE_GUARD_PATTERN = RailsAiContext::Install::InitializerFile::BARE_GUARD

      def select_ai_tools
        @selected_formats = RailsAiContext::Install::Program.select_ai_tools(program_surface)
      end

      def cleanup_removed_tools
        @previous_formats = read_previous_ai_tools
        return unless @previous_formats&.any?

        RailsAiContext::Install::Program.cleanup_removed_tools(
          program_surface,
          previous: @previous_formats, selected: @selected_formats, root: Rails.root
        )
      end

      def select_tool_mode
        @tool_mode = RailsAiContext::Install::Program.select_tool_mode(program_surface)
      end

      def create_mcp_config
        RailsAiContext::Install::Program.write_mcp_configs(
          program_surface,
          tools: @selected_formats, tool_mode: @tool_mode, root: Rails.root
        )
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
            #   :mcp - MCP primary + CLI fallback (default, requires `rails ai:serve`)
            #   :cli - CLI only (no MCP server needed, uses `rails 'ai:tool[NAME]'`)
            # config.tool_mode = :mcp
        SECTION
        "Introspection" => <<~SECTION,
            # ── Introspection ─────────────────────────────────────────────────
            # Introspector preset:
            #   :full     - all #{CountPhrase.call(RailsAiContext::Configuration::PRESETS[:full].size, 'introspector')} (default)
            #   :standard - #{CountPhrase.call(RailsAiContext::Configuration::PRESETS[:standard].size, 'core introspector')} (schema, models, routes, jobs, gems,
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
            #   :auto - enable if `listen` gem is available (default)
            #   true  - enable, raise if `listen` gem is missing
            #   false - disable entirely
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
            # Register additional MCP tool classes alongside the #{CountPhrase.call(RailsAiContext::Server.builtin_tools.size, 'built-in tool')}
            # config.custom_tools = ["MyApp::CustomTool"]  # class name as string - resolved after boot

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
        "Database Query Tool" => <<~SECTION,
            # ── Database Query Tool (rails_query) ─────────────────────────────
            # Per-query statement timeout in seconds. Default: 5.
            # config.query_timeout = 5

            # Hard cap on rows returned by a single query (1..1000).
            # Prevents accidentally pulling a million-row table into the
            # AI's context. Default: 100.
            # config.query_row_limit = 100

            # Additional column names whose values are redacted in tool
            # output. Defaults already cover password_digest,
            # encrypted_password, *_token, *_secret, *_key, etc.
            # config.query_redacted_columns += %w[my_app_specific_secret]

            # rails_query is DISABLED in production by default. Setting
            # this to true is rarely correct - only do so if you have
            # audit logging + access controls around your AI client.
            # config.allow_query_in_production = false
        SECTION
        "Log Reading" => <<~SECTION,
            # ── Log Reading (rails_read_logs) ─────────────────────────────────
            # Default tail length when reading a log file. Larger values
            # surface more context but cost more AI tokens per call.
            # config.log_lines = 50
        SECTION
        "Hydration" => <<~SECTION,
            # ── Hydration ─────────────────────────────────────────────────────
            # When enabled, MCP tool responses include schema hints telling
            # the AI which related tools to call next. Helps agents
            # traverse the introspection graph efficiently. Default: true.
            # config.hydration_enabled = true

            # Maximum number of hydration hints embedded per tool response.
            # config.hydration_max_hints = 5
        SECTION
        "Search" => <<~SECTION,
            # ── Search ────────────────────────────────────────────────────────
            # File extensions the Ruby fallback searches (ripgrep searches every file)
            # config.search_extensions = %w[rb js erb yml yaml json ts tsx vue svelte haml slim]

            # Where to look for concern source files. Left unset, every
            # app/*/concerns directory is discovered. Setting this replaces
            # that list, so it can narrow as well as reach outside app/.
            # config.concern_paths = %w[app/models/concerns lib/concerns]
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
      # Thor's `ask` returns nil when stdin hits EOF (e.g. piping fewer answers
      # than prompts, or `< /dev/null`), which crashes the very next `.strip`
      # call. Every prompt in this generator treats an empty answer as "use
      # the default", so collapsing both the EOF case and `--defaults` to ""
      # here lets each call site's existing empty-string handling do the rest.
      def ask_safe(statement, **opts)
        return "" if options[:defaults]
        ask(statement, **opts).to_s
      end

      # The install program's voice on this entry: Thor's say with colours,
      # ask_safe so --defaults answers every prompt with its default.
      def program_surface
        @program_surface ||= begin
          generator = self
          surface = Object.new
          surface.define_singleton_method(:say) do |text = "", level = :plain|
            colour = { emph: :yellow, ok: :green, warn: :red, muted: :yellow }[level]
            colour ? generator.say(text, colour) : generator.say(text)
          end
          surface.define_singleton_method(:ask) do |prompt|
            generator.send(:ask_safe, prompt)
          end
          surface
        end
      end

      def create_new_initializer(path)
        # Always write uncommented so re-install can detect previous selection
        tools_line = RailsAiContext::Install::SelectionRecord.initializer_line(@selected_formats)

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
            #   :mcp - MCP primary + CLI fallback (default, requires `rails ai:serve`)
            #   :cli - CLI only (no MCP server needed, uses `rails 'ai:tool[NAME]'`)
          #{tool_mode_line}

        SECTION

        # All remaining sections use defaults (commented out). They go through
        # the same reindent the update path uses: the AI Tools section above
        # carries the configure body's indent and these are written flush, so
        # appending them raw left the file with two indents, and the guard wrap
        # preserved the gap by indenting both equally.
        CONFIG_SECTIONS.each do |name, section_content|
          next if name == "AI Tools" # already added with dynamic values
          content += reindent_section_content(section_content, content) + "\n"
        end

        content += "end\n"
        content, = ensure_initializer_guard(content)

        create_file path, content
        say "Created #{path} with all #{CountPhrase.call(CONFIG_SECTIONS.size, "config section")}", :green
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
          say "#{full_path.relative_path_from(Rails.root)} is up to date - no changes needed", :green
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
          # Key not found at all - don't add (it's in a section that will be added)
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
        return upgrade_bare_guard(content) if guarded_initializer?(content)

        header_match = content.match(/\A# frozen_string_literal: true\n(?:\n)?/)
        header = header_match ? "# frozen_string_literal: true\n\n" : ""
        body = header_match ? content.delete_prefix(header_match[0]) : content
        body = "#{body}\n" unless body.end_with?("\n")

        wrapped = "#{header}#{RailsAiContext::Install::InitializerFile::GUARD_LINE}\n#{indent_content(body)}end\n"
        [ wrapped, wrapped != content ]
      end

      # Upgrades an initializer still on the bare `if defined?(RailsAiContext)`
      # guard (written before this gem checked respond_to?(:configure)) in place.
      # No-op if the guard is already the current form.
      def upgrade_bare_guard(content)
        upgraded = content.sub(BARE_GUARD_PATTERN) do
          "#{Regexp.last_match(1)}#{RailsAiContext::Install::InitializerFile::GUARD_LINE}"
        end
        [ upgraded, upgraded != content ]
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
        RailsAiContext::Install::InitializerFile.guarded?(content)
      end

      def indent_content(content)
        content.lines.map { |line| line == "\n" ? line : "  #{line}" }.join
      end

      def build_ai_tools_line
        # Always write uncommented so re-install can detect previous selection
        RailsAiContext::Install::SelectionRecord.initializer_line(@selected_formats)
      end

      def build_tool_mode_line
        if @tool_mode == :cli
          "  config.tool_mode = :cli    # CLI only (no MCP server needed)"
        else
          "  config.tool_mode = :mcp   # MCP primary + CLI fallback"
        end
      end

      def read_previous_ai_tools
        RailsAiContext::Install::SelectionRecord.read(root: Rails.root)
      end
      end # no_tasks

      def create_yaml_config
        # `initializer: false` because this generator writes that file itself,
        # a few steps earlier and better: it replaces the commented-out
        # default in place, where the module would insert a line and leave the
        # comment behind. One writer per file, and it is not this call.
        result = RailsAiContext::Install::SelectionRecord.write(
          @selected_formats, root: Rails.root,
          extra_yaml: { "tool_mode" => @tool_mode.to_s },
          initializer: false
        )

        RailsAiContext::Install::SelectionRecord.messages(result).each do |level, text|
          say text, { ok: :green, muted: :yellow, warn: :red }.fetch(level)
        end
      end

      def add_to_gitignore
        RailsAiContext::Install::Program.mark_gitignore(program_surface, root: Rails.root)
      end

      def install_validation_hook
        git_dir = Rails.root.join(".git")
        return unless Dir.exist?(git_dir)

        hooks_dir = git_dir.join("hooks")
        hook_path = hooks_dir.join("pre-commit")

        if File.exist?(hook_path) && !File.read(hook_path).include?("rails-ai-context")
          say "  Skipped pre-commit hook (existing hook found - add manually)", :yellow
          return
        end

        return if File.exist?(hook_path) && File.read(hook_path).include?("rails-ai-context")

        answer = ask_safe("Install a pre-commit hook that validates Rails references? (y/N)").strip.downcase
        return unless answer == "y"

        # Standalone installs have no `ai:*` rake tasks, so the hook must call
        # the gem's own binary; in-Gemfile installs go through rake as usual.
        if RailsAiContext::InstallMode.standalone?
          hook_binary = "rails-ai-context"
          validate_command = %(rails-ai-context tool validate --files "$files")
        else
          hook_binary = "rails"
          validate_command = %(rails 'ai:tool[validate]' files="$files")
        end

        FileUtils.mkdir_p(hooks_dir)
        File.write(hook_path, <<~HOOK)
          #!/bin/bash
          # rails-ai-context: validate Rails references before commit
          # Catches hallucinated columns, missing models, and schema drift.
          # Remove this file or the rails-ai-context section to disable.

          changed_files=$(git diff --cached --name-only | grep -E '\\.(rb|erb)$' || true)

          if [ -z "$changed_files" ]; then
            exit 0
          fi

          if command -v #{hook_binary} &> /dev/null; then
            files=$(printf '%s\\n' "$changed_files" | tr '\\n' ',')
            #{validate_command} 2>/dev/null
            exit_code=$?
            if [ $exit_code -ne 0 ]; then
              echo ""
              echo "rails-ai-context validation found issues."
              echo "Fix them or skip with: git commit --no-verify"
              exit $exit_code
            fi
          fi
        HOOK
        FileUtils.chmod(0o755, hook_path)
        say "  Installed pre-commit validation hook", :green
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

        # Generate every selected format in ONE call so ContextFileSerializer's
        # cross-format dedup applies (opencode and codex share AGENTS.md and
        # its split rules - generating them one format at a time defeats that
        # dedup and reports the same file as both written and unchanged).
        begin
          result = RailsAiContext.generate_context(format: @selected_formats)
          (result[:written] || []).each { |f| say "  ✅ #{f}", :green }
          (result[:skipped] || []).each { |f| say "  ⏭️  #{f} (unchanged)", :yellow }
        rescue => e
          say "  ❌ #{@selected_formats.join(', ')}: #{e.message}", :red
        end
      end

      def show_instructions
        say ""
        say "=" * 50, :cyan
        say " rails-ai-context installed!", :cyan
        say "=" * 50, :cyan
        say ""
        say "Your setup:", :yellow
        RailsAiContext::Install::AiTool.all.each do |tool|
          next unless @selected_formats.include?(tool.key)
          say "  ✅ #{tool.name.ljust(16)} -> #{tool.files}"
        end
        say ""
        say "Commands:", :yellow
        say "  rails ai:context         # Regenerate context files"
        tool_count = RailsAiContext::Server.builtin_tools.size
        say "  rails 'ai:tool[schema]'    # Run any of the #{CountPhrase.call(tool_count, "tool")} from CLI"
        if @tool_mode == :mcp
          say "  rails ai:serve           # Start MCP server (#{CountPhrase.call(tool_count, "live tool")})"
        end
        say "  rails ai:facts           # Print concise schema facts summary"
        say "  rails 'ai:preset[arch]'   # Run multi-tool presets (architecture, debugging, migration)"
        say "  rails ai:doctor          # Check AI readiness"
        say "  rails ai:inspect         # Print introspection summary"
        say ""
        if @tool_mode == :mcp
          say "MCP auto-discovery:", :yellow
          say "  Each AI tool gets its own config file - auto-detected on project open."
          say "  No manual config needed."
        else
          say "CLI tools:", :yellow
          say "  AI agents can run `rails 'ai:tool[schema]' table=users` directly."
          say "  No MCP server needed - tools work from the terminal."
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
        if @selected_formats.include?(:codex)
          say "Commit context files and MCP configs so your team benefits! (.codex/config.toml stays local - it embeds machine-specific paths; add it to .gitignore)", :green
        else
          say "Commit context files and MCP config files so your team benefits!", :green
        end
      end
    end
  end
end
