# frozen_string_literal: true

ASSISTANT_TABLE = <<~TABLE
  AI Assistant       Context File                          Command
  --                 --                                    --
  Claude Code        CLAUDE.md                             rails ai:context:claude
  Cursor             .cursorrules                          rails ai:context:cursor
  Windsurf           .windsurfrules                        rails ai:context:windsurf
  GitHub Copilot     .github/copilot-instructions.md       rails ai:context:copilot
  JSON (generic)     .ai-context.json                      rails ai:context:json
TABLE

namespace :ai do
  desc "Generate AI context files (CLAUDE.md, .cursorrules, .windsurfrules, .github/copilot-instructions.md)"
  task context: :environment do
    require "rails_ai_context"

    puts "🔍 Introspecting #{Rails.application.class.module_parent_name}..."

    puts "📝 Writing context files..."
    files = RailsAiContext.generate_context(format: :all)

    files.each { |f| puts "  ✅ #{f}" }
    puts ""
    puts "Done! Your AI assistants now understand your Rails app."
    puts "Commit these files so your whole team benefits."
    puts ""
    puts ASSISTANT_TABLE
  end

  desc "Generate AI context in a specific format (claude, cursor, windsurf, copilot, json)"
  task :context_for, [ :format ] => :environment do |_t, args|
    require "rails_ai_context"

    format = (args[:format] || ENV["FORMAT"] || "claude").to_sym
    puts "🔍 Introspecting #{Rails.application.class.module_parent_name}..."

    puts "📝 Writing #{format} context file..."
    files = RailsAiContext.generate_context(format: format)

    files.each { |f| puts "  ✅ #{f}" }
  end

  namespace :context do
    { claude: "CLAUDE.md", cursor: ".cursorrules", windsurf: ".windsurfrules",
      copilot: ".github/copilot-instructions.md", json: ".ai-context.json" }.each do |fmt, file|
      desc "Generate #{file} context file"
      task fmt => :environment do
        require "rails_ai_context"

        puts "🔍 Introspecting #{Rails.application.class.module_parent_name}..."
        puts "📝 Writing #{file}..."
        files = RailsAiContext.generate_context(format: fmt)

        files.each { |f| puts "  ✅ #{f}" }
        puts ""
        puts "Tip: Run `rails ai:context` to generate all formats at once."
      end
    end
  end

  desc "Start the MCP server (stdio transport, for Claude Code / Cursor)"
  task serve: :environment do
    require "rails_ai_context"

    RailsAiContext.start_mcp_server(transport: :stdio)
  end

  desc "Start the MCP server with HTTP transport"
  task serve_http: :environment do
    require "rails_ai_context"

    RailsAiContext.start_mcp_server(transport: :http)
  end

  desc "Print introspection summary to stdout (useful for debugging)"
  task inspect: :environment do
    require "rails_ai_context"
    require "json"

    context = RailsAiContext.introspect

    puts "=" * 60
    puts " #{context[:app_name]} — AI Context Summary"
    puts "=" * 60
    puts ""
    puts "Rails #{context[:rails_version]} | Ruby #{context[:ruby_version]}"
    puts ""

    if context[:schema] && !context[:schema][:error]
      puts "📦 Database: #{context[:schema][:total_tables]} tables (#{context[:schema][:adapter]})"
    end

    if context[:models] && !context[:models].is_a?(Hash)
      puts "🏗️  Models: #{context[:models].size}"
    elsif context[:models].is_a?(Hash) && !context[:models][:error]
      puts "🏗️  Models: #{context[:models].size}"
    end

    if context[:routes] && !context[:routes][:error]
      puts "🛤️  Routes: #{context[:routes][:total_routes]}"
    end

    if context[:jobs]
      puts "⚡ Jobs: #{context[:jobs][:jobs]&.size || 0}"
      puts "📧 Mailers: #{context[:jobs][:mailers]&.size || 0}"
    end

    if context[:conventions]
      arch = context[:conventions][:architecture] || []
      puts "🏛️  Architecture: #{arch.join(', ')}" if arch.any?
    end

    puts ""
    puts ASSISTANT_TABLE
    puts ""
    puts "Run `rails ai:context` to generate context files."
  end
end
