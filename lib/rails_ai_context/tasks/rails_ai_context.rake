# frozen_string_literal: true

# Built from Install::AiTool rather than typed out: the hand-written copy had
# already drifted, printing a Copilot row that omitted .github/instructions/.
ASSISTANT_TABLE = begin
  rows = RailsAiContext::Install::AiTool.all.map { |tool|
    [ tool.name, tool.files, "rails ai:context:#{tool.key}" ]
  }
  rows << [ "JSON (generic)", ".ai-context.json", "rails ai:context:json" ]

  name_width = rows.map { |r| r[0].length }.max
  file_width = rows.map { |r| r[1].length }.max

  header = [ "AI Assistant".ljust(name_width), "Context File".ljust(file_width), "Command" ]
  divider = [ "--".ljust(name_width), "--".ljust(file_width), "--" ]

  ([ header, divider ] + rows)
    .map { |name, files, command| "  #{name.ljust(name_width)}  #{files.ljust(file_width)}  #{command}".rstrip }
    .join("\n") + "\n"
end unless defined?(ASSISTANT_TABLE)

def print_result(result)
  result[:written].each { |f| puts "  ✅ #{f}" }
  result[:skipped].each { |f| puts "  ⏭️  #{f} (unchanged)" }
end unless defined?(print_result)

def abort_boot_failure(result, timeout)
  $stderr.puts "Error: Rails app failed to boot: #{result.failure_summary}"
  if result.error.is_a?(RailsAiContext::BootManager::BootTimeoutError)
    $stderr.puts "  If the app is healthy but slow, raise RAILS_AI_CONTEXT_BOOT_TIMEOUT (seconds, current: #{timeout})."
  end
  exit 1
end

def apply_context_mode_override
  if ENV["CONTEXT_MODE"]
    mode = ENV["CONTEXT_MODE"].to_sym
    RailsAiContext.configuration.context_mode = mode
    puts "📐 Context mode: #{mode}"
  end
end unless defined?(apply_context_mode_override)

# The install program's voice on this entry: plain puts, an emoji on the
# outcomes the task has always marked.
def install_surface
  @rails_ai_context_install_surface ||= begin
    surface = Object.new
    def surface.say(text = "", level = :plain)
      prefix = { ok: "✅ ", warn: "⚠️  " }[level]
      puts "#{prefix}#{text}"
    end
    def surface.ask(prompt)
      print "#{prompt} "
      $stdin.gets&.strip
    end
    surface
  end
end unless defined?(install_surface)

def prompt_ai_tools
  RailsAiContext::Install::Program.select_ai_tools(install_surface)
end unless defined?(prompt_ai_tools)

def prompt_tool_mode
  RailsAiContext::Install::Program.select_tool_mode(install_surface)
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

def ensure_mcp_configs(ai_tools = nil)
  tools = ai_tools || RailsAiContext.configuration.ai_tools || RailsAiContext::McpConfigGenerator::TOOL_CONFIGS.keys
  RailsAiContext::Install::Program.write_mcp_configs(
    install_surface,
    tools: tools, tool_mode: RailsAiContext.configuration.tool_mode, root: Rails.root
  )
rescue => e
  puts "⚠️  Could not create MCP config files: #{e.message}"
end unless defined?(ensure_mcp_configs)

def tool_mode_configured?
  !RailsAiContext::Install::SelectionRecord.tool_mode(root: Rails.root).nil?
rescue => e
  $stderr.puts "[rails-ai-context] tool_mode_configured? failed: #{e.message}" if ENV["DEBUG"]
  false
end unless defined?(tool_mode_configured?)

# `record_initializer:` is false on an ordinary `ai:context` run. The YAML is
# this gem's own file and is refreshed every time, but the initializer is the
# user's Rails config: rewriting it unasked would renormalize their line and
# drop any key this version does not recognise.
def save_selection(ai_tools, tool_mode, record_initializer: false)
  result = RailsAiContext::Install::SelectionRecord.write(
    ai_tools, root: Rails.root,
    extra_yaml: { "tool_mode" => tool_mode.to_s },
    initializer: record_initializer
  )

  RailsAiContext::Install::SelectionRecord.messages(result).each do |level, text|
    puts "#{level == :warn ? '⚠️ ' : '💾'} #{text}"
  end
rescue => e
  $stderr.puts "[rails-ai-context] save_selection failed: #{e.message}" if ENV["DEBUG"]
  nil
end unless defined?(save_selection)


def read_previous_ai_tools_from_config
  RailsAiContext::Install::SelectionRecord.read(root: Rails.root)
end unless defined?(read_previous_ai_tools_from_config)

def cleanup_removed_ai_tools(previous, current)
  RailsAiContext::Install::Program.cleanup_removed_tools(
    install_surface, previous: previous, selected: current, root: Rails.root
  )
end unless defined?(cleanup_removed_ai_tools)

def add_ai_context_to_gitignore
  RailsAiContext::Install::Program.mark_gitignore(install_surface, root: Rails.root)
end unless defined?(add_ai_context_to_gitignore)

# Writing only the initializer here was the last hand-rolled record left: it
# left the YAML behind, and the initializer wins on read, so a per-tool
# context run could put the two files into exactly the disagreement
# SelectionRecord exists to prevent.
def add_ai_tool_to_initializer(format)
  result = RailsAiContext::Install::SelectionRecord.add(format, root: Rails.root)
  RailsAiContext::Install::SelectionRecord.messages(result).each do |level, text|
    puts "#{level == :warn ? '⚠️ ' : '💾'} #{text}"
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
    exit 1 if runner.error
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
    previous_tools = read_previous_ai_tools_from_config

    # First time - no tools configured, ask the user. The record is written
    # once below, so the selection reaches both files together.
    prompted = ai_tools.nil?
    ai_tools = prompt_ai_tools if prompted

    # Prompt for tool_mode if not yet configured in initializer
    unless tool_mode_configured?
      tool_mode = prompt_tool_mode
      RailsAiContext.configuration.tool_mode = tool_mode
      save_tool_mode_to_initializer(tool_mode)
    end

    # Cleanup removed tools (only when re-running with different selections)
    cleanup_removed_ai_tools(previous_tools, ai_tools) if previous_tools&.any? && ai_tools

    # One-time v5.0.0 legacy cleanup prompt for removed UI pattern files
    RailsAiContext::LegacyCleanup.prompt_legacy_files(ai_tools, root: Rails.root)

    # Record the selection (the YAML enables standalone mode). The initializer
    # is only touched on the run that actually asked the user.
    save_selection(ai_tools || RailsAiContext.configuration.ai_tools,
                   RailsAiContext.configuration.tool_mode,
                   record_initializer: prompted)

    # Auto-create/update per-tool MCP config files when tool_mode is :mcp
    ensure_mcp_configs(ai_tools) if RailsAiContext.configuration.tool_mode == :mcp

    # Add .ai-context.json to .gitignore
    add_ai_context_to_gitignore

    puts "🔍 Introspecting #{Rails.application.class.module_parent_name}..."

    if ai_tools.nil? || ai_tools.empty?
      puts "📝 Writing context files for all AI tools..."
      result = RailsAiContext.generate_context(format: :all)
      print_result(result)
    else
      puts "📝 Writing context files for: #{ai_tools.map(&:to_s).join(', ')}..."
      # One call for every selected format so ContextFileSerializer's
      # cross-format dedup applies (opencode and codex share AGENTS.md and
      # its split rules - generating one format at a time defeats that dedup
      # and reports the same file as both written and unchanged).
      result = RailsAiContext.generate_context(format: ai_tools)
      print_result(result)
    end

    puts ""
    if Array(ai_tools).include?(:codex)
      puts "Done! Commit context files and MCP configs so your team benefits."
      puts "(.codex/config.toml stays local - it embeds machine-specific paths; add it to .gitignore)"
    else
      puts "Done! Commit these files so your team benefits."
    end
    puts "Change AI tools: config/initializers/rails_ai_context.rb (config.ai_tools)"
    puts ""
    puts "Standalone (no Gemfile needed):"
    puts "  gem install rails-ai-context"
    puts "  rails-ai-context init          # interactive setup"
    puts "  rails-ai-context serve         # start MCP server"
  end

  desc "Generate AI context in a specific format (claude, cursor, copilot, opencode, codex, json)"
  task :context_for, [ :format ] => :environment do |_t, args|
    require "rails_ai_context"

    apply_context_mode_override

    format = (args[:format] || ENV["FORMAT"] || "claude").to_sym
    RailsAiContext::LegacyCleanup.prompt_legacy_files([ format ], root: Rails.root)
    puts "🔍 Introspecting #{Rails.application.class.module_parent_name}..."

    puts "📝 Writing #{format} context file..."
    result = RailsAiContext.generate_context(format: format)

    print_result(result)
  end

  namespace :context do
    per_tool = RailsAiContext::Install::AiTool.all.to_h { |tool| [ tool.key, tool.files ] }
    per_tool.merge(json: ".ai-context.json").each do |fmt, file|
      desc "Generate #{file} context file"
      task fmt => :environment do
        require "rails_ai_context"

        apply_context_mode_override

        RailsAiContext::LegacyCleanup.prompt_legacy_files([ fmt ], root: Rails.root)
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
      RailsAiContext::LegacyCleanup.prompt_legacy_files(
        RailsAiContext.configuration.ai_tools, root: Rails.root
      )
      puts "🔍 Introspecting #{Rails.application.class.module_parent_name} (full mode)..."
      puts "📝 Writing context files..."
      result = RailsAiContext.generate_context(format: :all)

      print_result(result)
      puts ""
      puts "Done! Full context files generated (all details included)."
    end
  end

  desc "Start the MCP server (stdio transport, auto-discovered by configured AI tools)"
  task :serve do
    # Boot inside the task so app boot output (initializer puts, deprecation
    # warnings) is quarantined to stderr - stdout carries the JSON-RPC stream.
    # Through Rake's environment task, not BootManager.boot!, so app hooks on
    # that task still run; the guard adds the timeout and the rescue.
    timeout = RailsAiContext::BootManager.env_timeout
    result = RailsAiContext::BootManager.guard(timeout: timeout) do
      Rake::Task["environment"].invoke
    end
    abort_boot_failure(result, timeout) unless result.booted?
    require "rails_ai_context"

    RailsAiContext.start_mcp_server(transport: :stdio)
  end

  desc "Start the MCP server with HTTP transport"
  task :serve_http do
    timeout = RailsAiContext::BootManager.env_timeout
    result = RailsAiContext::BootManager.guard(timeout: timeout) do
      Rake::Task["environment"].invoke
    end
    abort_boot_failure(result, timeout) unless result.booted?
    require "rails_ai_context"

    RailsAiContext.start_mcp_server(transport: :http)
  end

  desc "Print introspection summary to stdout (useful for debugging)"
  task inspect: :environment do
    require "rails_ai_context"
    require "json"

    context = RailsAiContext.introspect

    puts "=" * 60
    puts " #{context[:app_name]} - AI Context Summary"
    puts "=" * 60
    puts ""
    puts "Rails #{context[:rails_version]} | Ruby #{context[:ruby_version]}"
    puts ""

    if context[:schema] && !context[:schema][:error]
      puts "📦 Database: #{RailsAiContext::CountPhrase.call(context[:schema][:total_tables], "table")} (#{RailsAiContext::SchemaAdapter.label(context)})"
    end

    if context[:models] && !context[:models].is_a?(Hash)
      puts "🏗️  Models: #{context[:models].size}"
    elsif context[:models].is_a?(Hash) && !context[:models][:error]
      puts "🏗️  Models: #{context[:models].size}"
    end

    if context[:routes] && !context[:routes][:error]
      puts "🛤️  Routes: #{context[:routes][:total_routes]}#{RailsAiContext::RouteCoverage.suffix(context[:routes])}"
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

  desc "Run a multi-tool preset: rails ai:preset[architecture], rails ai:preset[debugging], rails ai:preset[migration]"
  task :preset, [ :name ] => :environment do |_t, args|
    require "rails_ai_context"

    presets = RailsAiContext::Presets::DEFINITIONS

    name = args[:name]&.strip&.downcase
    unless name && presets.key?(name)
      puts "Available presets:"
      puts ""
      presets.each do |key, info|
        puts "  rails 'ai:preset[#{key}]'".ljust(38) + "# #{info[:desc]}"
      end
      next
    end

    preset = presets[name]
    # All framing goes to stderr so stdout stays pure tool output - mixing
    # the two scrambles ordering under pipes (stderr is unbuffered, piped
    # stdout is block-buffered).
    $stderr.puts "=" * 60
    $stderr.puts " Preset: #{name} - #{preset[:desc]}"
    $stderr.puts "=" * 60
    $stderr.puts ""

    preset[:tools].each do |tool_spec|
      begin
        $stderr.puts "-" * 40
        $stderr.puts "Running: #{tool_spec[:name]}"
        $stderr.puts "-" * 40
        runner = RailsAiContext::CLI::ToolRunner.new(
          tool_spec[:name],
          tool_spec[:params]
        )
        puts runner.run
        puts ""
      rescue => e
        $stderr.puts "  [error] #{tool_spec[:name]}: #{e.message}"
      end
    end
  end

  desc "Print a concise schema facts summary (tables, columns, indexes, associations, dependencies)"
  task facts: :environment do
    require "rails_ai_context"

    context = RailsAiContext.introspect
    puts RailsAiContext::FactsFormatter.render(context, inspect_hint: "rails ai:inspect")
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

    # STRICT=1 turns doctor into a CI gate: exit 1 when any check fails.
    if %w[1 true yes].include?(ENV["STRICT"].to_s.downcase)
      failed = result[:checks].count { |c| c.status == :fail }
      if failed > 0
        puts "#{RailsAiContext::CountPhrase.call(failed, "check")} failed (STRICT mode)"
        exit 1
      end
    end
  end
end
