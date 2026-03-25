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
        "4" => { key: :windsurf, name: "Windsurf",        files: ".windsurfrules + .windsurf/rules/",                  format: :windsurf },
        "5" => { key: :opencode, name: "OpenCode",        files: "AGENTS.md",                                          format: :opencode }
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

      def create_mcp_config
        mcp_path = Rails.root.join(".mcp.json")
        server_entry = {
          "command" => "bundle",
          "args" => [ "exec", "rails", "ai:serve" ]
        }

        if File.exist?(mcp_path)
          existing = JSON.parse(File.read(mcp_path)) rescue {}
          existing["mcpServers"] ||= {}

          if existing["mcpServers"]["rails-ai-context"]
            say ".mcp.json already has rails-ai-context — skipped", :yellow
          else
            existing["mcpServers"]["rails-ai-context"] = server_entry
            File.write(mcp_path, JSON.pretty_generate(existing) + "\n")
            say "Added rails-ai-context to existing .mcp.json", :green
          end
        else
          create_file ".mcp.json", JSON.pretty_generate({
            mcpServers: { "rails-ai-context" => server_entry }
          }) + "\n"
          say "Created .mcp.json (auto-discovered by Claude Code, Cursor, etc.)", :green
        end
      end

      def create_initializer
        tools_line = if @selected_formats.size == AI_TOOLS.size
          "  # config.ai_tools = %i[claude cursor copilot windsurf opencode]  # default: all"
        else
          "  config.ai_tools = %i[#{@selected_formats.join(' ')}]"
        end

        create_file "config/initializers/rails_ai_context.rb", <<~RUBY
          # frozen_string_literal: true

          RailsAiContext.configure do |config|
            # AI tools to generate context files for (selected during install)
            # Run `rails generate rails_ai_context:install` to change selection
          #{tools_line}

            # Introspector preset:
            #   :full     — all 28 introspectors (default)
            #   :standard — 13 core introspectors
            # config.preset = :full

            # Models to exclude from introspection
            # config.excluded_models += %w[AdminUser InternalThing]

            # Context mode: :compact (default, ≤150 lines) or :full (dumps everything)
            # config.context_mode = :compact

            # Live reload: auto-invalidate MCP tool caches on file changes
            # config.live_reload = :auto
          end
        RUBY

        say "Created config/initializers/rails_ai_context.rb", :green
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
        say "  rails ai:serve           # Start MCP server (25 live tools)"
        say "  rails ai:doctor          # Check AI readiness"
        say "  rails ai:inspect         # Print introspection summary"
        say ""
        say "MCP auto-discovery:", :yellow
        say "  .mcp.json is auto-detected by Claude Code and Cursor."
        say "  No manual config needed — just open your project."
        say ""
        say "To add more AI tools later:", :yellow
        say "  rails ai:context:cursor   # Generate for Cursor"
        say "  rails ai:context:copilot  # Generate for Copilot"
        say "  rails generate rails_ai_context:install  # Re-run to pick tools"
        say ""
        say "Commit context files and .mcp.json so your team benefits!", :green
      end
    end
  end
end
