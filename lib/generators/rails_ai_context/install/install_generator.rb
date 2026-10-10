# frozen_string_literal: true

require "json"
require "open3"
require "shellwords"
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
      desc "Install rails-ai-context: creates initializer, MCP config, and generates initial context files."

      class_option :defaults, type: :boolean, default: false,
        desc: "Skip all interactive prompts and use each prompt's documented default (for CI/non-interactive use)"

      class_option :mcp_only, type: :boolean, default: false,
        desc: "Write the MCP config and nothing else: no CLAUDE.md, AGENTS.md, rules files or .ai-context.json"

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

      def select_setup
        if options[:mcp_only]
          @tool_mode = :mcp
          @context_files = false
          return
        end

        setup = RailsAiContext::Install::Program.select_setup(program_surface)
        @tool_mode = setup.tool_mode
        @context_files = setup.context_files
      end

      def create_mcp_config
        RailsAiContext::Install::Program.write_mcp_configs(
          program_surface,
          tools: @selected_formats, tool_mode: @tool_mode, root: Rails.root
        )
        return unless @tool_mode == :cli

        program = RailsAiContext::Install::Program
        program.remove_mcp_entries(program_surface, program.ask_mcp_removal(program_surface, root: Rails.root),
                                   root: Rails.root)
      end

      # The :standard preset's comment, its introspectors named from the
      # preset itself and wrapped under the line, so the list cannot fall
      # behind the code the way a typed copy did.
      def self.standard_preset_comment
        names = RailsAiContext::Configuration::PRESETS[:standard].map(&:to_s)
        lines = [ "#   :standard - #{CountPhrase.call(names.size, 'core introspector')} (" ]
        names.each_with_index do |name, index|
          word = "#{name}#{index == names.size - 1 ? ')' : ','}"
          if lines.last.end_with?("(")
            lines[-1] += word
          elsif lines.last.length + word.length + 1 > 74
            lines << "#               #{word}"
          else
            lines[-1] += " #{word}"
          end
        end
        lines.join("\n")
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

            # Whether this gem writes context files at all. false is MCP-only:
            # the server and the CLI still answer, and CLAUDE.md, AGENTS.md,
            # the rules directories and .ai-context.json are left alone.
            # config.context_files = true
        SECTION
        "Introspection" => <<~SECTION,
            # ── Introspection ─────────────────────────────────────────────────
            # Introspector preset:
            #   :full     - all #{CountPhrase.call(RailsAiContext::Configuration::PRESETS[:full].size, 'introspector')} (default)
            #{standard_preset_comment}
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
            # config.max_view_total_size = 10_000_000  # Doctor view-size threshold (10MB)
            # config.max_view_file_size = 1_000_000    # Accepted and stored; no check reads it (1MB)
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

            # Column names a query may not touch: one that names any of them
            # is rejected before it runs, and a returned column of that name
            # comes back [FILTERED]. The defaults already list password_digest,
            # encrypted_password, api_key, access_token and the like, and a
            # built-in list is checked on top of them.
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
            # Narrow the Ruby fallback to these extensions. Unset, it searches
            # every file, as ripgrep does, so the two backends agree.
            # config.search_extensions = %w[rb js erb yml yaml json ts tsx vue svelte haml slim]

            # Where to look for concern source files. Left unset, every
            # app/concerns and app/*/concerns directory is discovered. Setting this replaces
            # that list, so it can narrow as well as reach outside app/.
            # config.concern_paths = %w[app/models/concerns lib/concerns]
        SECTION
        "Frontend" => <<~SECTION
            # ── Frontend Framework Detection ─────────────────────────────────
            # Auto-detected from package.json, config/vite.json, etc. Override only if needed.
            # A path outside the app root is read for package.json, lockfiles, bundler config and its tsconfig.json.
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
        @program_surface ||= RailsAiContext::Install::Surface.new(
          lambda { |text, level|
            colour = { emph: :yellow, ok: :green, warn: :red, muted: :yellow }[level]
            colour ? say(text, colour) : say(text)
          },
          ->(prompt) { ask_safe(prompt) }
        )
      end

      def create_new_initializer(path)
        # Always write uncommented so re-install can detect previous selection
        tools_line = build_ai_tools_line

        tool_mode_line = build_tool_mode_line

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
          #{build_context_files_line}

        SECTION

        # All remaining sections use defaults (commented out). They go through
        # the same reindent the update path uses: the AI Tools section above
        # carries the configure body's indent and these are written flush, so
        # appending them raw left the file with two indents, and the guard wrap
        # preserved the gap by indenting both equally. One blank line between
        # sections and none before `end`, as the app's Rubocop wants it.
        sections = CONFIG_SECTIONS.except("AI Tools") # already added with dynamic values
        content += sections.values.map { |section_content| reindent_section_content(section_content, content) }.join("\n")

        content += "end\n"
        content, = ensure_initializer_guard(content)

        create_file path, content
        say "Created #{path} with all #{CountPhrase.call(CONFIG_SECTIONS.size, "config section")}", :green
      end

      def update_existing_initializer(full_path)
        existing = File.read(full_path)
        changes = []

        # 1. Update ai_tools selection if user picked new tools
        existing, changed = update_config_line(existing, :ai_tools, @selected_formats)
        changes << "ai_tools" if changed

        # 2. Update tool_mode if user picked a new mode
        existing, changed = update_config_line(existing, :tool_mode, tool_mode)
        changes << "tool_mode" if changed

        # 3. Record whether this install writes context files at all
        existing, changed = update_config_line(existing, :context_files, context_files?)
        changes << "context_files" if changed

        # 4. Add any missing config sections
        CONFIG_SECTIONS.each do |name, section_content|
          marker = "── #{name}"
          next if existing.include?(marker)

          insert_point = configure_block_end_index(existing)
          if insert_point
            # A blank line above the section unless one is there, or the block
            # is empty, and none below it: the line before `end` stays code.
            above = existing[0...insert_point]
            gap = above.end_with?("\n\n") || above.match?(/do \|config\|\n\z/) ? "" : "\n"
            existing = existing.insert(insert_point, "#{gap}#{reindent_section_content(section_content, existing)}")
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

      # A key's line, rewritten where it stands. An assignment in the shape
      # the record writes keeps its indentation and whatever follows the
      # value, and is left alone when it already holds the value; any other
      # assignment, or the commented-out default, becomes the generated line.
      # A key with no line is not added: it comes with its section.
      # Returns [new_content, changed?]
      def update_config_line(content, key, value)
        record = RailsAiContext::Install::SelectionRecord
        edited, status = record.edit_config_line(content, key, value, insert: false)
        return [ edited, status == :updated ] unless %i[conflict absent].include?(status)

        pattern = /^([ \t]*)#?[ \t]*config\.#{key}[ \t]*=.*$/
        updated = content.sub(pattern) { "#{Regexp.last_match(1)}#{record.config_line(key, value)}" }
        [ updated, updated != content ]
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

      # The three selection lines, at the configure body's indent. Always
      # written uncommented, so a re-run reads the same answers the last one
      # recorded.
      def build_ai_tools_line
        "  #{RailsAiContext::Install::SelectionRecord.config_line(:ai_tools, @selected_formats)}"
      end

      def build_tool_mode_line
        "  #{RailsAiContext::Install::SelectionRecord.config_line(:tool_mode, tool_mode)}"
      end

      def build_context_files_line
        "  #{RailsAiContext::Install::SelectionRecord.config_line(:context_files, context_files?)}"
      end

      def tool_mode
        @tool_mode == :cli ? :cli : :mcp
      end

      def context_files?
        @context_files.nil? ? true : @context_files
      end

      def read_previous_ai_tools
        RailsAiContext::Install::SelectionRecord.read(root: Rails.root)
      end

      # Git's own answer, not a `.git` directory in Rails.root: a submodule
      # has a `.git` file, a monorepo app has its `.git` above it, and
      # core.hooksPath moves the hooks elsewhere, where a hook written to
      # .git/hooks would never run. `--git-path` and `--git-common-dir` answer
      # relative to the directory they run in. The prefix is where the app
      # sits in the work tree; git runs a hook at the top of it.
      def git_repository
        out, status = Open3.capture2("git", "rev-parse", "--git-path", "hooks", "--show-prefix", "--show-toplevel",
                                     "--git-common-dir", chdir: Rails.root.to_s, err: File::NULL)
        # Paths that are no UTF-8 cannot be named in the hook as text.
        out = out.dup.force_encoding(Encoding::UTF_8)
        return nil unless status.success? && out.valid_encoding?

        hooks, prefix, toplevel, common_dir = out.lines.map(&:chomp)
        return nil if toplevel.to_s.empty?

        root = Rails.root.to_s
        { hooks: Pathname.new(File.expand_path(hooks, root)), prefix: prefix.to_s.delete_suffix("/"),
          toplevel: File.expand_path(toplevel, root), common_dir: File.expand_path(common_dir.to_s, root) }
      rescue SystemCallError
        nil
      end

      # Whether `path` is `dir` or below it, compared by real paths: a hooks
      # directory may not exist yet, and a temp or home directory may sit
      # behind a symlink.
      def inside?(path, dir)
        RailsAiContext::SafePath.contained?(RailsAiContext::SafePath.canonical(path), RailsAiContext::SafePath.canonical(dir))
      end

      # Whether git tracks any file of the app, asked from inside it.
      def app_tracked?
        out, status = Open3.capture2("git", "ls-files", "-z", "--", ".", chdir: Rails.root.to_s, err: File::NULL)
        status.success? && !out.empty?
      rescue SystemCallError
        false
      end

      def write_validation_hook(path, dir, script)
        FileUtils.mkdir_p(dir)
        File.write(path, script)
        FileUtils.chmod(0o755, path)
      end

      # Why a hook that runs rails-ai-context but is not one this version
      # wrote, as it stands, is left alone. It may be the gem's, changed by
      # hand since, or somebody's own that calls the gem among other checks,
      # so nothing here suggests replacing it.
      def hand_changed_hook(path, content, listed, app)
        if listed
          "#{path} validates #{listed.join(', ')} and was changed by hand - add #{app} to it the same way"
        elsif content.include?("# rails-ai-context apps:")
          "#{path} names its apps in a form this version cannot read - add #{app} to it by hand"
        else
          "#{path} already runs rails-ai-context and is not a hook this version wrote as it stands, so it is left " \
            "as it is - make sure it passes deleted files over, as the current hook does"
        end
      end
      end # no_tasks

      def create_yaml_config
        # `initializer: false` because this generator writes that file itself,
        # a few steps earlier and better: it replaces the commented-out
        # default in place, where the module would insert a line and leave the
        # comment behind. One writer per file, and it is not this call.
        result = RailsAiContext::Install::SelectionRecord.write(
          @selected_formats, root: Rails.root,
          extra_yaml: { "tool_mode" => @tool_mode.to_s, "context_files" => context_files? },
          initializer: false
        )

        RailsAiContext::Install::SelectionRecord.messages(result).each do |level, text|
          say text, { ok: :green, muted: :yellow, warn: :red }.fetch(level)
        end
      end

      def add_to_gitignore
        RailsAiContext::Install::Program.mark_gitignore(program_surface, root: Rails.root,
                                                        context_files: context_files?)
      end

      def install_validation_hook
        repo = git_repository or return

        # A core.hooksPath outside the repository is shared by every
        # repository that uses it, so this app's hook does not belong there.
        unless inside?(repo[:hooks], repo[:toplevel]) || inside?(repo[:hooks], repo[:common_dir])
          say "  Skipped pre-commit hook (core.hooksPath points outside this repository, at #{repo[:hooks]}, " \
              "where every repository using it would run it - add it there by hand)", :yellow
          return
        end

        app = repo[:prefix].empty? ? "." : repo[:prefix]
        # An app below the top of a repository it is not tracked in - one
        # under a dotfiles repository at $HOME - is not that repository's to
        # validate.
        unless app == "." || app_tracked?
          say "  Skipped pre-commit hook (#{Rails.root} is not tracked in the git repository at #{repo[:toplevel]} - " \
              "commit it there, then run this again)", :yellow
          return
        end

        hook_path = repo[:hooks].join("pre-commit")
        hook = RailsAiContext::Install::ValidationHook
        apps = [ app ]
        standalone = RailsAiContext::InstallMode.standalone?
        if File.exist?(hook_path)
          content = File.binread(hook_path)
          unless content.include?("rails-ai-context")
            say "  Skipped pre-commit hook (existing hook found - add manually)", :yellow
            return
          end

          coverage = hook.coverage(content)
          unless coverage
            listed = hook.listed(content)
            return if listed&.include?(app)

            say "  Skipped pre-commit hook (#{hand_changed_hook(hook_path, content, listed, app)})", :yellow
            return
          end

          # An earlier version's hook, unchanged: rewritten in the current form,
          # which leaves deleted files out, without asking again for the app
          # that took it.
          if coverage.legacy && app == "."
            write_validation_hook(hook_path, repo[:hooks], hook.script(apps, standalone: standalone))
            say "  Updated the pre-commit validation hook from an earlier version", :green
            return
          end
          return if coverage.apps.include?(app)

          # Another app in the same repository: the hook is rewritten to cover
          # this one too, in the form it was written in.
          standalone = coverage.standalone unless coverage.legacy
          apps = coverage.apps + [ app ]
        end

        where = app == "." ? "" : " in #{repo[:toplevel]}"
        question = if apps.one?
          "Install a pre-commit hook#{where} that checks staged Ruby and ERB files for syntax errors? (y/N)"
        else
          "Add #{app} to the pre-commit hook#{where} that checks staged Ruby and ERB files for syntax errors? (y/N)"
        end
        answer = ask_safe(question).strip.downcase
        return unless answer == "y"

        write_validation_hook(hook_path, repo[:hooks], hook.script(apps, standalone: standalone))
        say(apps.one? ? "  Installed pre-commit validation hook" : "  Added #{app} to the pre-commit validation hook", :green)
      end

      def generate_context_files
        unless context_files?
          say ""
          say "MCP-only install: no context files written.", :yellow
          return
        end

        say ""
        say "Generating AI context files...", :yellow

        unless Rails.application
          say "  Skipped (Rails app not fully loaded). Run `rails ai:context` after install.", :yellow
          return
        end

        require "rails_ai_context"

        # One-time v5.0.0 legacy UI-pattern files cleanup prompt
        RailsAiContext::LegacyCleanup.prompt_legacy_files(
          @selected_formats, root: Rails.root, warn_only: options[:defaults]
        )

        # The configuration was loaded at boot, before the questions above:
        # without the answers the files came out in the mode the app had
        # before, MCP form under a choice of CLI.
        config = RailsAiContext.configuration
        config.ai_tools = @selected_formats
        config.tool_mode = tool_mode
        config.context_files = context_files?

        begin
          result = RailsAiContext.generate_context(format: @selected_formats)
          style = RailsAiContext::ContextFileReport.style(:emoji)
          RailsAiContext::ContextFileReport.each_line(result, style, root: Rails.root) do |bucket, text|
            say "  #{text}", RailsAiContext::ContextFileReport.color(bucket)
          end
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
          files = context_files? ? tool.files_label(mcp: tool_mode == :mcp) : "MCP config only"
          say "  ✅ #{tool.name.ljust(16)} -> #{files}"
        end
        unless context_files?
          say ""
          say "  Left alone on purpose: CLAUDE.md, AGENTS.md, the rules directories and .ai-context.json.", :yellow
        end
        say ""
        say "Commands:", :yellow
        say "  rails ai:context                 # Regenerate context files"
        # What the server serves, skip_tools and custom_tools applied.
        tool_count = RailsAiContext::Server.exposed_tools.size
        say "  rails 'ai:tool[schema]'          # Run any of the #{CountPhrase.call(tool_count, "tool")} from CLI"
        if @tool_mode == :mcp
          say "  rails ai:serve                   # Start MCP server (#{CountPhrase.call(tool_count, "live tool")})"
        end
        say "  rails ai:facts                   # Print concise schema facts summary"
        say "  rails 'ai:preset[architecture]'  # Run a multi-tool preset (architecture, debugging, migration)"
        say "  rails ai:doctor                  # Check AI readiness"
        say "  rails ai:inspect                 # Print introspection summary"
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
