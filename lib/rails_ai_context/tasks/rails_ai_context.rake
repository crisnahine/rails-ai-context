# frozen_string_literal: true

ASSISTANT_TABLE = <<~TABLE unless defined?(ASSISTANT_TABLE)
  AI Assistant       Context File                          Command
  --                 --                                    --
  Claude Code        CLAUDE.md + .claude/rules/            rails ai:context:claude
  OpenCode           AGENTS.md                             rails ai:context:opencode
  Cursor             .cursor/rules/                        rails ai:context:cursor
  GitHub Copilot     .github/copilot-instructions.md       rails ai:context:copilot
  JSON (generic)     .ai-context.json                      rails ai:context:json
TABLE

def print_result(result)
  result[:written].each { |f| puts "  ✅ #{f}" }
  result[:skipped].each { |f| puts "  ⏭️  #{f} (unchanged)" }
end unless defined?(print_result)

def apply_context_mode_override
  if ENV["CONTEXT_MODE"]
    mode = ENV["CONTEXT_MODE"].to_sym
    RailsAiContext.configuration.context_mode = mode
    puts "📐 Context mode: #{mode}"
  end
end unless defined?(apply_context_mode_override)

AI_TOOL_OPTIONS = {
  "1" => { key: :claude,   name: "Claude Code" },
  "2" => { key: :cursor,   name: "Cursor" },
  "3" => { key: :copilot,  name: "GitHub Copilot" },
  "4" => { key: :opencode, name: "OpenCode" }
}.freeze unless defined?(AI_TOOL_OPTIONS)

def prompt_ai_tools
  puts ""
  puts "Which AI tools do you use? (select all that apply)"
  puts ""
  AI_TOOL_OPTIONS.each { |num, info| puts "  #{num}. #{info[:name]}" }
  puts "  a. All of the above"
  puts ""
  print "Enter numbers separated by commas (e.g. 1,2) or 'a' for all: "
  input = $stdin.gets&.strip&.downcase || "a"

  selected = if input == "a" || input == "all" || input.empty?
    AI_TOOL_OPTIONS.values.map { |t| t[:key] }
  else
    input.split(/[\s,]+/).filter_map { |n| AI_TOOL_OPTIONS[n]&.dig(:key) }
  end

  if selected.empty?
    puts "No tools selected — using all."
    selected = AI_TOOL_OPTIONS.values.map { |t| t[:key] }
  end

  names = AI_TOOL_OPTIONS.values.select { |t| selected.include?(t[:key]) }.map { |t| t[:name] }
  puts "Selected: #{names.join(', ')}"
  selected
end unless defined?(prompt_ai_tools)

def prompt_tool_mode
  puts ""
  puts "Do you also want MCP server support?"
  puts ""
  puts "  1. Yes — MCP primary + CLI fallback (generates .mcp.json)"
  puts "  2. No  — CLI only (no server needed)"
  puts ""
  print "Enter number (default: 1): "
  input = $stdin.gets&.strip || "1"

  mode = input == "2" ? :cli : :mcp
  label = mode == :mcp ? "MCP + CLI fallback" : "CLI only"
  puts "Selected: #{label}"
  mode
end unless defined?(prompt_tool_mode)

def save_tool_mode_to_initializer(mode)
  init_path = Rails.root.join("config/initializers/rails_ai_context.rb")
  return unless File.exist?(init_path)

  content = File.read(init_path)
  mode_line = "  config.tool_mode = :#{mode}"

  if content.include?("config.tool_mode")
    content.sub!(/^.*config\.tool_mode.*$/, mode_line)
  elsif content.include?("config.ai_tools")
    # Insert after ai_tools line
    content.sub!(/^(.*config\.ai_tools.*)$/, "\\1\n#{mode_line}")
  elsif content.include?("RailsAiContext.configure")
    content.sub!(/RailsAiContext\.configure do \|config\|\n/, "RailsAiContext.configure do |config|\n#{mode_line}\n")
  else
    return
  end

  File.write(init_path, content)
rescue => e
  $stderr.puts "[rails-ai-context] save_tool_mode_to_initializer failed: #{e.message}" if ENV["DEBUG"]
  nil
end unless defined?(save_tool_mode_to_initializer)

def ensure_mcp_json
  mcp_path = Rails.root.join(".mcp.json")
  return if File.exist?(mcp_path)

  server_entry = { "command" => "bundle", "args" => [ "exec", "rails", "ai:serve" ] }
  content = JSON.pretty_generate({ mcpServers: { "rails-ai-context" => server_entry } }) + "\n"
  File.write(mcp_path, content)
  puts "✅ Created .mcp.json (MCP auto-discovery for Claude Code, Cursor, etc.)"
rescue => e
  puts "⚠️  Could not create .mcp.json: #{e.message}"
end unless defined?(ensure_mcp_json)

def tool_mode_configured?
  init_path = Rails.root.join("config/initializers/rails_ai_context.rb")
  return false unless File.exist?(init_path)
  content = File.read(init_path)
  # Check for uncommented tool_mode line (not just a comment)
  content.match?(/^\s*config\.tool_mode\s*=/)
rescue => e
  $stderr.puts "[rails-ai-context] tool_mode_configured? failed: #{e.message}" if ENV["DEBUG"]
  false
end unless defined?(tool_mode_configured?)

def save_ai_tools_to_initializer(tools)
  init_path = Rails.root.join("config/initializers/rails_ai_context.rb")
  return unless File.exist?(init_path)

  content = File.read(init_path)
  tools_line = "  config.ai_tools = %i[#{tools.join(' ')}]"

  if content.include?("config.ai_tools")
    # Replace existing ai_tools line
    content.sub!(/^.*config\.ai_tools.*$/, tools_line)
  elsif content.include?("RailsAiContext.configure")
    # Insert after configure block opening
    content.sub!(/RailsAiContext\.configure do \|config\|\n/, "RailsAiContext.configure do |config|\n#{tools_line}\n")
  else
    return
  end

  File.write(init_path, content)
  puts "💾 Saved to config/initializers/rails_ai_context.rb"
rescue => e
  $stderr.puts "[rails-ai-context] save_ai_tools_to_initializer failed: #{e.message}" if ENV["DEBUG"]
  nil
end unless defined?(save_ai_tools_to_initializer)

def add_ai_tool_to_initializer(format)
  init_path = Rails.root.join("config/initializers/rails_ai_context.rb")
  return unless File.exist?(init_path)

  content = File.read(init_path)
  format_sym = format.to_s

  # Find the ai_tools line (commented or uncommented)
  if content.match?(/^\s*config\.ai_tools\s*=\s*%i\[([^\]]*)\]/)
    # Uncommented line — add format if not present
    match = content.match(/^\s*config\.ai_tools\s*=\s*%i\[([^\]]*)\]/)
    current_tools = match[1].split.map(&:strip)
    unless current_tools.include?(format_sym)
      current_tools << format_sym
      new_line = "  config.ai_tools = %i[#{current_tools.join(' ')}]"
      content.sub!(/^\s*config\.ai_tools\s*=\s*%i\[[^\]]*\]/, new_line)
      File.write(init_path, content)
      puts "💾 Added :#{format_sym} to config.ai_tools"
    end
  elsif content.match?(/^\s*#\s*config\.ai_tools\s*=/)
    # Commented line — uncomment and set to just this format
    content.sub!(/^\s*#\s*config\.ai_tools\s*=.*$/, "  config.ai_tools = %i[#{format_sym}]")
    File.write(init_path, content)
    puts "💾 Set config.ai_tools = %i[#{format_sym}]"
  end
rescue => e
  $stderr.puts "[rails-ai-context] add_ai_tool_to_initializer failed: #{e.message}" if ENV["DEBUG"]
  nil
end unless defined?(add_ai_tool_to_initializer)

namespace :ai do
  desc "Run an MCP tool from the CLI: rails 'ai:tool[schema]' table=users detail=full"
  task :tool, [ :name ] => :environment do |_t, args|
    require "rails_ai_context"

    name = args[:name]

    unless name
      puts RailsAiContext::CLI::ToolRunner.tool_list
      next
    end

    # Parse key=value pairs from ARGV (skip rake-internal args)
    params = {}
    ARGV.each do |arg|
      next if arg.start_with?("-") || arg.include?("[") || arg == "ai:tool"
      if arg.include?("=")
        key, value = arg.split("=", 2)
        params[key.to_sym] = value
      end
    end

    json_mode = ENV["JSON"] == "1"

    if params.delete(:help) || ARGV.include?("--help")
      runner = RailsAiContext::CLI::ToolRunner.new(name, {})
      puts RailsAiContext::CLI::ToolRunner.tool_help(runner.tool_class)
      next
    end

    runner = RailsAiContext::CLI::ToolRunner.new(name, params, json_mode: json_mode)
    puts runner.run
  rescue RailsAiContext::CLI::ToolRunner::ToolNotFoundError => e
    $stderr.puts "Error: #{e.message}"
    exit 1
  rescue RailsAiContext::CLI::ToolRunner::InvalidArgumentError => e
    $stderr.puts "Error: #{e.message}"
    exit 3
  rescue => e
    $stderr.puts "Error: #{e.message}"
    exit 2
  end

  desc "Generate AI context files for configured AI tools (prompts on first run)"
  task context: :environment do
    require "rails_ai_context"

    apply_context_mode_override

    ai_tools = RailsAiContext.configuration.ai_tools

    # First time — no tools configured, ask the user
    if ai_tools.nil?
      ai_tools = prompt_ai_tools
      save_ai_tools_to_initializer(ai_tools) if ai_tools
    end

    # Prompt for tool_mode if not yet configured in initializer
    unless tool_mode_configured?
      tool_mode = prompt_tool_mode
      RailsAiContext.configuration.tool_mode = tool_mode
      save_tool_mode_to_initializer(tool_mode)
    end

    # Auto-create .mcp.json when tool_mode is :mcp and it doesn't exist
    ensure_mcp_json if RailsAiContext.configuration.tool_mode == :mcp

    puts "🔍 Introspecting #{Rails.application.class.module_parent_name}..."

    if ai_tools.nil? || ai_tools.empty?
      puts "📝 Writing context files for all AI tools..."
      result = RailsAiContext.generate_context(format: :all)
      print_result(result)
    else
      puts "📝 Writing context files for: #{ai_tools.map(&:to_s).join(', ')}..."
      ai_tools.each do |fmt|
        result = RailsAiContext.generate_context(format: fmt)
        print_result(result)
      end
    end

    puts ""
    puts "Done! Commit these files so your team benefits."
    puts "Change AI tools: config/initializers/rails_ai_context.rb (config.ai_tools)"
  end

  desc "Generate AI context in a specific format (claude, cursor, copilot, json)"
  task :context_for, [ :format ] => :environment do |_t, args|
    require "rails_ai_context"

    apply_context_mode_override

    format = (args[:format] || ENV["FORMAT"] || "claude").to_sym
    puts "🔍 Introspecting #{Rails.application.class.module_parent_name}..."

    puts "📝 Writing #{format} context file..."
    result = RailsAiContext.generate_context(format: format)

    print_result(result)
  end

  namespace :context do
    { claude: "CLAUDE.md", opencode: "AGENTS.md", cursor: ".cursor/rules/",
      copilot: ".github/copilot-instructions.md", json: ".ai-context.json" }.each do |fmt, file|
      desc "Generate #{file} context file"
      task fmt => :environment do
        require "rails_ai_context"

        apply_context_mode_override

        puts "🔍 Introspecting #{Rails.application.class.module_parent_name}..."
        puts "📝 Writing #{file}..."
        result = RailsAiContext.generate_context(format: fmt)

        print_result(result)

        # Add this format to config.ai_tools if not already there
        add_ai_tool_to_initializer(fmt)

        puts ""
        puts "Tip: Run `rails ai:context` to generate all formats at once."
      end
    end

    desc "Generate AI context files in full mode (dumps everything)"
    task full: :environment do
      require "rails_ai_context"

      RailsAiContext.configuration.context_mode = :full
      puts "🔍 Introspecting #{Rails.application.class.module_parent_name} (full mode)..."
      puts "📝 Writing context files..."
      result = RailsAiContext.generate_context(format: :all)

      print_result(result)
      puts ""
      puts "Done! Full context files generated (all details included)."
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

  desc "Watch for changes and auto-regenerate context files (requires listen gem)"
  task watch: :environment do
    require "rails_ai_context"

    RailsAiContext::Watcher.new.start
  end

  desc "Run diagnostic checks and report AI readiness score"
  task doctor: :environment do
    require "rails_ai_context"

    puts "🩺 Running AI readiness diagnostics..."
    puts ""

    result = RailsAiContext::Doctor.new.run

    result[:checks].each do |check|
      icon = case check.status
      when :pass then "✅"
      when :warn then "⚠️ "
      when :fail then "❌"
      end
      puts "  #{icon} #{check.name}: #{check.message}"
      puts "     Fix: #{check.fix}" if check.fix
    end

    puts ""
    puts "AI Readiness Score: #{result[:score]}/100"
  end
end
