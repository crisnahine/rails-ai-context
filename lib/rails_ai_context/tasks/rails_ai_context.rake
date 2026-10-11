# frozen_string_literal: true

# Built from Install::AiTool rather than typed out: the hand-written copy had
# already drifted, printing a Copilot row that omitted .github/instructions/.
# A row names what its command writes, so Codex's MCP config, which only the
# install writes, is not in it.
ASSISTANT_TABLE = begin
  rows = RailsAiContext::Install::AiTool.all.map { |tool|
    [ tool.name, tool.context_files, "rails ai:context:#{tool.key}" ]
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
  style = RailsAiContext::ContextFileReport.style(:emoji)
  RailsAiContext::ContextFileReport.each_line(result, style, root: Rails.root) { |_bucket, text| puts "  #{text}" }
end unless defined?(print_result)

def abort_boot_failure(result, timeout)
  $stderr.puts "Error: Rails app failed to boot: #{result.failure_summary(full: true)}"
  if result.error.is_a?(RailsAiContext::BootManager::BootTimeoutError)
    $stderr.puts "  If the app is healthy but slow, raise RAILS_AI_CONTEXT_BOOT_TIMEOUT (seconds, current: #{timeout})."
  end
  result.configure_hint.each { |line| $stderr.puts "  #{line}" }
  exit 1
end unless defined?(abort_boot_failure)

# Boots through Rake's environment task so app hooks run, with boot output kept off
# stdout (the JSON-RPC stream, or a JSON=1 envelope); the guard adds the timeout
# and the rescue.
def boot_quietly
  timeout = RailsAiContext::BootManager.env_timeout
  result = RailsAiContext::BootManager.guard(timeout: timeout) do
    Rake::Task["environment"].invoke
  end
  abort_boot_failure(result, timeout) unless result.booted?
  require "rails_ai_context"
end unless defined?(boot_quietly)

# A stdio client gives up on `initialize` after about 30 seconds, so a hung
# boot has to fail before that for the client to see why (STDIO_TIMEOUT).
def boot_and_serve(transport)
  RailsAiContext::BootManager.default_timeout = RailsAiContext::BootManager::STDIO_TIMEOUT if transport == :stdio
  boot_quietly
  RailsAiContext.start_mcp_server(transport: transport)
end unless defined?(boot_and_serve)

# Called before the task does any work, so an unknown mode stops it with the
# valid ones named rather than writing files nobody asked for.
def apply_context_mode_override
  return unless ENV["CONTEXT_MODE"]

  mode = ENV["CONTEXT_MODE"].to_sym
  RailsAiContext.configuration.context_mode = mode
  puts "📐 Context mode: #{mode}"
rescue ArgumentError
  $stderr.puts "Error: CONTEXT_MODE=#{ENV['CONTEXT_MODE']} is not a context mode. " \
               "Valid: #{RailsAiContext::Configuration::CONTEXT_MODES.join(', ')}"
  exit 1
end unless defined?(apply_context_mode_override)

# The install program's voice on this entry: plain puts, an emoji on the
# outcomes the task has always marked.
def install_surface
  @rails_ai_context_install_surface ||= RailsAiContext::Install::Surface.new(
    lambda { |text, level|
      prefix = { ok: "✅ ", warn: "⚠️  " }[level]
      puts "#{prefix}#{text}"
    },
    lambda { |prompt|
      print "#{prompt} "
      $stdin.gets&.strip
    }
  )
end unless defined?(install_surface)

def prompt_ai_tools
  RailsAiContext::Install::Program.select_ai_tools(install_surface)
end unless defined?(prompt_ai_tools)

def prompt_setup
  RailsAiContext::Install::Program.select_setup(install_surface)
end unless defined?(prompt_setup)

def say_conflict(key, status)
  _level, text = RailsAiContext::Install::SelectionRecord.conflict_message(key, status)
  puts "⚠️  #{text}" if text
end unless defined?(say_conflict)

# Each returns the line's write status (:updated, :inserted, :unchanged,
# :conflict, :absent), so the run can name the initializer when it moved.
def save_tool_mode_to_initializer(mode)
  status = RailsAiContext::Install::SelectionRecord.write_tool_mode(mode, root: Rails.root)
  say_conflict(:tool_mode, status)
  status
rescue => e
  RailsAiContext.debug_fail(e, nil, label: "save_tool_mode_to_initializer")
end unless defined?(save_tool_mode_to_initializer)

def save_context_files_to_initializer(value)
  status = RailsAiContext::Install::SelectionRecord.write_context_files(value, root: Rails.root)
  say_conflict(:context_files, status)
  status
rescue => e
  RailsAiContext.debug_fail(e, nil, label: "save_context_files_to_initializer")
end unless defined?(save_context_files_to_initializer)

def ensure_mcp_configs(ai_tools = nil)
  tools = ai_tools || RailsAiContext.configuration.ai_tools || RailsAiContext::McpConfigGenerator::TOOL_CONFIGS.keys
  tools = RailsAiContext::Install::Program.own_config_tools(tools, root: Rails.root)
  return if tools.empty?

  RailsAiContext::Install::Program.write_mcp_configs(
    install_surface,
    tools: tools, tool_mode: RailsAiContext.configuration.tool_mode, root: Rails.root
  )
rescue => e
  puts "⚠️  Could not create MCP config files: #{e.message}"
end unless defined?(ensure_mcp_configs)

def tool_mode_configured?
  RailsAiContext::Install::SelectionRecord.tool_mode_set?(root: Rails.root)
rescue => e
  RailsAiContext.debug_fail(e, false, label: "tool_mode_configured?")
end unless defined?(tool_mode_configured?)

# `record_initializer:` is false on an ordinary `ai:context` run. The YAML is
# this gem's own file and is refreshed every time, but the initializer is the
# user's Rails config: rewriting it unasked would renormalize their line and
# drop any key this version does not recognise. `initializer_moved:` says the
# run already rewrote the initializer's mode or context_files line, so the
# file is named once, whichever of its lines moved.
def save_selection(ai_tools, tool_mode, record_initializer: false, initializer_moved: false)
  result = RailsAiContext::Install::SelectionRecord.write(
    ai_tools, root: Rails.root,
    extra_yaml: { "tool_mode" => tool_mode.to_s,
                  "context_files" => RailsAiContext.configuration.context_files },
    initializer: record_initializer
  )
  if initializer_moved && %i[unchanged absent skipped].include?(result[:initializer])
    result = result.merge(initializer: :updated)
  end

  RailsAiContext::Install::SelectionRecord.messages(result).each do |level, text|
    puts "#{level == :warn ? '⚠️ ' : '💾'} #{text}"
  end
rescue => e
  RailsAiContext.debug_fail(e, nil, label: "save_selection")
end unless defined?(save_selection)


# Where the selection a user would edit lives: the initializer's line when it
# has one, since that wins on read, else the YAML record. Naming the
# initializer always sent an app that has none to a file that is not there.
def ai_tools_record_hint
  record = RailsAiContext::Install::SelectionRecord
  initializer = Rails.root.join(record::INITIALIZER)
  if File.exist?(initializer) && File.read(initializer).match?(/^[ \t]*config\.ai_tools\s*=/)
    "#{record::INITIALIZER} (config.ai_tools)"
  else
    "#{record::YAML_FILE} (ai_tools)"
  end
end unless defined?(ai_tools_record_hint)

def read_previous_ai_tools_from_config
  RailsAiContext::Install::SelectionRecord.read(root: Rails.root)
end unless defined?(read_previous_ai_tools_from_config)

def cleanup_removed_ai_tools(previous, current)
  RailsAiContext::Install::Program.cleanup_removed_tools(
    install_surface, previous: previous, selected: current, root: Rails.root
  )
end unless defined?(cleanup_removed_ai_tools)

def add_ai_context_to_gitignore
  RailsAiContext::Install::Program.mark_gitignore(
    install_surface, root: Rails.root, context_files: RailsAiContext.configuration.context_files
  )
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
  RailsAiContext.debug_fail(e, nil, label: "add_ai_tool_to_initializer")
end unless defined?(add_ai_tool_to_initializer)

namespace :ai do
  desc "Run an MCP tool from the CLI: rails 'ai:tool[schema]' table=users detail=full"
  task :tool, [ :name ] do |_t, args|
    # Booted here rather than as a prerequisite, so what the app prints while
    # it boots goes to stderr, as it does from the binary: with JSON=1, stdout
    # is the envelope and nothing else.
    boot_quietly

    name = args[:name]

    unless name
      puts RailsAiContext::CLI::ToolRunner.tool_list
      next
    end

    # Parse key=value pairs from ARGV, skipping the task itself: a value
    # holds a bracket as often as the task does (`pattern=params\[:id\]`).
    params = {}
    ARGV.each do |arg|
      next if arg.start_with?("-") || arg.match?(/\Aai:tool(?:\[|\z)/)
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
  # One status for a question that went unanswered, whichever surface asked
  # it: docs/CLI.md states it as the rule and the binary has always answered
  # it. This task answered 3 for a bad argument and 2 for anything else, so a
  # wrapper keying on the status got two answers to one typo.
  rescue => e
    $stderr.puts "Error: #{e.message}"
    exit 1
  end

  desc "Generate AI context files for configured AI tools (prompts on first run)"
  task context: :environment do
    require "rails_ai_context"

    apply_context_mode_override

    # An MCP-only install asked for no context files. Saying so and stopping
    # beats prompting for tools whose files this run would not write.
    unless RailsAiContext.configuration.context_files
      puts "MCP-only install (config.context_files = false): no context files written."
      puts "Run `rails 'ai:context:claude'` to write one anyway, or set config.context_files = true."
      next
    end

    ai_tools = RailsAiContext.configuration.ai_tools
    previous_tools = read_previous_ai_tools_from_config

    # First time - no tools configured, ask the user. The record is written
    # once below, so the selection reaches both files together.
    prompted = ai_tools.nil?
    if prompted
      ai_tools = prompt_ai_tools
      RailsAiContext.configuration.ai_tools = ai_tools
    end

    # Prompt for tool_mode if not yet configured in initializer
    initializer_moved = false
    unless tool_mode_configured?
      setup = prompt_setup
      RailsAiContext.configuration.tool_mode = setup.tool_mode
      RailsAiContext.configuration.context_files = setup.context_files
      statuses = [ save_tool_mode_to_initializer(setup.tool_mode),
                   save_context_files_to_initializer(setup.context_files) ]
      initializer_moved = statuses.any? { |status| %i[updated inserted].include?(status) }

      unless setup.context_files
        # Recorded like any other answer, or an app with no initializer
        # line to hold it was asked again on every run.
        save_selection(ai_tools, setup.tool_mode, record_initializer: prompted, initializer_moved: initializer_moved)
        puts "MCP-only install: no context files written."
        ensure_mcp_configs(ai_tools)
        next
      end
    end

    # Cleanup removed tools (only when re-running with different selections)
    cleanup_removed_ai_tools(previous_tools, ai_tools) if previous_tools&.any? && ai_tools

    # One-time v5.0.0 legacy cleanup prompt for removed UI pattern files
    RailsAiContext::LegacyCleanup.prompt_legacy_files(ai_tools, root: Rails.root)

    # Record the selection (the YAML enables standalone mode). The initializer
    # is only touched on the run that actually asked the user.
    save_selection(ai_tools || RailsAiContext.configuration.ai_tools,
                   RailsAiContext.configuration.tool_mode,
                   record_initializer: prompted, initializer_moved: initializer_moved)

    # Auto-create/update per-tool MCP config files when tool_mode is :mcp
    ensure_mcp_configs(ai_tools) if RailsAiContext.configuration.tool_mode == :mcp

    # Add .ai-context.json to .gitignore
    add_ai_context_to_gitignore

    puts "🔍 Introspecting #{Rails.application.class.module_parent_name}..."

    if ai_tools.nil? || ai_tools.empty?
      puts "📝 Writing context files for all AI tools..."
    else
      puts "📝 Writing context files for: #{ai_tools.map(&:to_s).join(', ')}..."
    end
    print_result(RailsAiContext.generate_context)

    puts ""
    mcp = RailsAiContext.configuration.tool_mode == :mcp
    puts mcp ? "Done! Commit the context files and MCP configs so your team benefits." : "Done! Commit these files so your team benefits."
    # Only where a Codex config was written, and only while a commit would
    # still take it along.
    if mcp && Array(ai_tools || RailsAiContext.configuration.ai_tools).include?(:codex) &&
       !RailsAiContext::Install::Program.codex_config_ignored?(Rails.root)
      puts "(.codex/config.toml stays local - it embeds machine-specific paths; add it to .gitignore)"
    end
    puts "Change AI tools: #{ai_tools_record_hint}"
  end

  desc "Generate AI context in a specific format (claude, cursor, copilot, opencode, codex, json)"
  task :context_for, [ :format ] => :environment do |_t, args|
    require "rails_ai_context"

    apply_context_mode_override

    format = (args[:format] || ENV["FORMAT"] || "claude").to_sym
    # Before the cleanup prompt and the introspection, both of which a format
    # nothing can write would waste, and in the binary's --format words.
    begin
      RailsAiContext::Serializers::ContextFileSerializer.validate_format!(format)
    rescue ArgumentError => e
      $stderr.puts "Error: #{e.message}"
      exit 1
    end
    RailsAiContext::LegacyCleanup.prompt_legacy_files([ format ], root: Rails.root)
    puts "🔍 Introspecting #{Rails.application.class.module_parent_name}..."

    puts format == :all ? "📝 Writing all context files..." : "📝 Writing #{format} context file..."
    result = RailsAiContext.generate_context(format: format)

    print_result(result)
  end

  namespace :context do
    # The task's description names the context files; the MCP config comes
    # with them, below, as the line the installer's tip promises.
    per_tool = RailsAiContext::Install::AiTool.all.to_h { |tool| [ tool.key, tool.context_files ] }
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

        # The tool joins the selection, so its MCP config comes with it, as
        # `rails ai:context` writes one for every tool selected: the rules
        # just written tell the AI to call the MCP tools.
        if RailsAiContext::Install::AiTool.find(fmt) && RailsAiContext.configuration.tool_mode == :mcp
          ensure_mcp_configs([ fmt ])
        end

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
    boot_and_serve(:stdio)
  end

  desc "Start the MCP server with HTTP transport"
  task :serve_http do
    boot_and_serve(:http)
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

    if (database = RailsAiContext::Serializers::SectionFacts.database_line(context))
      puts "📦 #{database.delete_prefix("- ")}"
    end

    if context[:models] && !context[:models].is_a?(Hash)
      puts "🏗️  Models: #{context[:models].size}"
    elsif RailsAiContext::Payload.models(context).any?
      puts "🏗️  Models: #{RailsAiContext::Payload.models(context).size}"
    end

    if (routes = RailsAiContext::Payload.section(context, :routes))
      puts "🛤️  Routes: #{RailsAiContext::RouteCoverage.summary(routes)}"
    end

    if context[:jobs]
      puts "⚡ Jobs: #{context[:jobs][:jobs]&.size || 0}"
      puts "📧 Mailers: #{context[:jobs][:mailers]&.size || 0}"
    end

    arch = RailsAiContext::Payload.architecture(context)
    puts "🏛️  Architecture: #{arch.join(', ')}" if arch.any?

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

    outcome = RailsAiContext::Presets.dispatch(
      args[:name], invocation: ->(k) { "rails 'ai:preset[#{k}]'" }
    )
    exit 1 unless RailsAiContext::Presets.ok?(outcome)
  end

  desc "Print a concise schema facts summary (tables, columns, indexes, associations, dependencies)"
  task facts: :environment do
    require "rails_ai_context"

    context = RailsAiContext.introspect
    # ai:inspect is a text summary; the whole payload as JSON is ai:context:json's file.
    puts RailsAiContext::FactsFormatter.render(
      context, full_json: "Run `rails ai:context:json` for the full introspection as JSON, in .ai-context.json."
    )
  end

  desc "Run diagnostic checks and report AI readiness score"
  task doctor: :environment do
    require "rails_ai_context"

    puts "🩺 Running AI readiness diagnostics..."
    puts ""

    result = RailsAiContext::Doctor.new.run

    puts RailsAiContext::Doctor.report_lines(result, icons: RailsAiContext::Doctor::EMOJI_ICONS)

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
