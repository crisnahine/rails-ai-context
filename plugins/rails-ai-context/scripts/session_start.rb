#!/usr/bin/env ruby
# frozen_string_literal: true

# The rules the generator's context files open with, for the app the server
# serves from here; the installed gem finds it, so the two always agree.
require_relative "gem_requirement"
requirement = Gem::Requirement.new(RailsAiContextPlugin::GEM_REQUIREMENT)
start = File.expand_path(ENV["CLAUDE_PROJECT_DIR"] || Dir.pwd)

# What Claude Code loads at launch for a session started here: the app's CLAUDE.md and rules file, and its
# AGENTS.md where CLAUDE.md imports it or none is on the way up. One below loads only once a file there is read.
# shortcut: Claude Code's default Project instructions setting; read its pluginConfigs if a changed one is reported.
carries = lambda do |path|
  begin
    File.binread(path).include?("Anti-Hallucination Protocol")
  rescue SystemCallError, IOError
    false
  end
end

begin
  # Activated as serve.rb activates it, so the rules come only where the server starts.
  Gem.activate_bin_path("rails-ai-context", "rails-ai-context", requirement.to_s)
  # Bundler's activate_bin_path drops the requirement, and the server refuses an older copy.
  spec = Gem.loaded_specs["rails-ai-context"]
  exit if spec && !requirement.satisfied_by?(spec.version)
  require "rails_ai_context/cli/app_root"
  require "rails_ai_context/gem_lock"
  app_root = RailsAiContext::CLI::AppRoot
  require "rails_ai_context/install/ai_tool"
  require "rails_ai_context/claude_code_settings"
  # The user's own memory, in the config folder Claude Code reads from here; nil where that is unknown.
  config_dir = RailsAiContext::ClaudeCodeSettings.user_config_dir
  user_memory = config_dir && File.join(config_dir, "CLAUDE.md")
  # The start folder up to the filesystem root, which Claude Code's walk stops short of.
  folders = [ start ]
  folders << File.dirname(folders.last) until File.dirname(folders.last) == folders.last
  folders.pop
  memories = folders.flat_map { |folder| %w[CLAUDE.md .claude/CLAUDE.md CLAUDE.local.md].map { |name| File.join(folder, name) } }
                    .select { |path| File.exist?(path) && !(user_memory && File.identical?(path, user_memory)) }
  # The server hands an app whose bundle locks an older copy of the gem to that copy, whose tools the rules do not name.
  older_copy = lambda do |app|
    named = ENV["BUNDLE_GEMFILE"].to_s
    gemfile = named.empty? ? RailsAiContext::GemLock.bundle(app).gemfile : named
    next false unless gemfile && app_root.lock_names_gem?(gemfile)

    handoff = app_root.bundled_handoff(app)
    handoff && !requirement.satisfied_by?(Gem::Version.new(handoff.version)) && app_root.bundle_ready?(handoff.env, app)
  end
  # Above several apps the rules hold for each, and the last line says how a call picks one.
  several = if RailsAiContextPlugin.routes?
    target = app_root.target(start)
    exit if target.kind == :none
    walked = target.resolution.walked
    root = target.root
    if target.kind == :apps
      bundled, served = target.apps.partition { |app| older_copy.(app.root) }
      roots = served.map(&:root)
      exit if roots.empty?
      names = target.apps.map { |app| bundled.include?(app) ? "#{app.name} (served by its own bundled copy)" : app.name }
      "This session's folder holds several Rails apps: #{names.join(", ")}. " \
        "Every rails_* tool takes `app`, one of those names, for the app to answer about."
    end
  else
    found = app_root.resolve(cwd: start)
    walked = found.walked
    root = found.root
    roots = found.below
    if root.nil? && found.below.size > 1
      "This session's folder holds several Rails apps, and the plugin's server serves none of them here: " \
        "run each app's tools as `rails-ai-context --app-path <app> tool <name>` from #{start}, " \
        "with <app> one of: #{found.below.map { |path| app_root.display(path, start) }.join(", ")}."
    end
  end
  unless several
    exit unless root && RailsAiContext::CLI::EntryBoot.app_present?(root, allow_source_only: true)
    roots = [ root ]
    exit if older_copy.(root)
  end
# A Ruby too old for the gem's own code fails to parse it, which no StandardError covers.
rescue ScriptError, StandardError
  exit
end

# Each app's settings as its boot applies them: whether the rules are on, and the tools skip_tools turns off.
# A release without the gem's reader: a configure block in application.rb or the environment's
# file runs before the config file loads and an initializer after it, so the last literal wins.
# shortcut: a literal that ends its statement only, not a value computed at boot; boot the app here if one is ever reported.
literals = lambda do |app|
  environment = [ ENV["RAILS_ENV"], ENV["RACK_ENV"] ].find { |name| !name.to_s.empty? } || "development"
  initializers = File.join(app, "config", "initializers")
  sources = [ File.join(app, "config", "application.rb"), File.join(app, "config", "environments", "#{environment}.rb"),
              *Dir.glob("**/*.rb", base: initializers).sort.map { |path| File.join(initializers, path) } ].filter_map do |path|
    begin
      File.binread(path).gsub("\r\n", "\n").gsub(/^=begin\b.*?^=end\b/m, "")
    rescue SystemCallError, IOError
      nil
    end
  end
  literal = ->(key, value) { sources.flat_map { |text| text.scan(/^[^#\n]*\.#{key}\s*=\s*(#{value})[ \t]*(?:[#;}]|\bend\b|$)/) }.flatten.last }
  file = begin
    require "yaml"
    require "date"
    YAML.safe_load_file(File.join(app, ".rails-ai-context.yml"), permitted_classes: [ Symbol, Date, Time ], aliases: true)
  rescue StandardError
    nil
  end
  file = {} unless file.is_a?(Hash)

  switch = literal.("anti_hallucination_rules", "true|false|nil")
  on = !(%w[false nil].include?(switch) || (switch.nil? && [ file["anti_hallucination_rules"], file[:anti_hallucination_rules] ].include?(false)))

  list = '%[wWiI](?:\[[^\]]*\]|\([^)]*\))|\[[^\]]*\]'
  names = ->(text) { text.scan(/%[wWiI][\[(]([^\])]*)[\])]|["':](\w+)/).flat_map { |words, name| name ? [ name ] : words.split } }
  listed = literal.("skip_tools", list)
  skipped = if listed
    names.(listed)
  else
    # Names alone: an alias-built list nests deep, and its text would run to gigabytes.
    Array(file["skip_tools"] || file[:skip_tools]).select { |name| name.is_a?(String) || name.is_a?(Symbol) }.map(&:to_s)
  end
  # A name appended in place adds to whichever list boot ends up with. Only += and |= go through the setter
  # that makes a symbol a name; the server never matches one the other forms append.
  operand = %(#{list}|["']\\w+["']|:\\w+)
  appended = sources.flat_map do |text|
    text.scan(/^[^#\n]*\.skip_tools\s*(<<|\+=|\|=|\.(?:push|append|concat)\b)\s*(\((?:[^()]|\([^()]*\))*\)|(?:#{operand})(?:[ \t]*(?:,|<<)\s*(?:#{operand}))*)[ \t]*(?:[#;}]|\bend\b|$)/)
  end
  [ on, skipped | appended.flat_map { |op, span| names.(%w[+= |=].include?(op) ? span : span.gsub(/%[iI](?:\[[^\]]*\]|\([^)]*\))|:\w+/, "")) } ]
end
stderr = $stderr
settings = roots.map do |app|
  next [ *literals.(app), [] ] unless RailsAiContextPlugin.gem_has?("rails_ai_context/unbooted_settings")

  begin
    # The gem's loader and the reader warn on stderr, which a hook would show the user.
    $stderr = File.open(File::NULL, "w")
    require "rails_ai_context"
    read = RailsAiContext::UnbootedSettings.read(app)
    # A skip_tools line the reader cannot follow may turn any tool off, so rule 3 then names no section.
    [ read.config.anti_hallucination_rules, read.skip_tools_refusal ? RailsAiContext::Tools::GetConfig::SECTIONS.map(&:tool_name) : read.config.skip_tools,
      read.respond_to?(:notes) ? read.notes : [] ]
  rescue ScriptError, StandardError
    [ *literals.(app), [] ]
  ensure
    $stderr.close unless $stderr.equal?(stderr)
    $stderr = stderr
  end
end
exit unless settings.any?(&:first)

# An app that turned the rules off still serves its own sections, so its skips count for rule 3.
skipped = settings.flat_map { |entry| entry[1] }.map(&:to_s).uniq
# A line the reader could not follow changed what the rules above were built from.
notes = roots.zip(settings).flat_map do |app, entry|
  entry[2].map { |note| "[rails-ai-context] #{several ? "#{app_root.display(app, start)}: " : ""}#{note}" }
end
rules = File.read(File.join(__dir__, "..", "rules.md"))
# Rule 3 names a rails_get_config section only where no app's skip_tools turns it off, as the generator writes it.
sections = { "conventions" => "rails_get_conventions", "gems" => "rails_get_gems" }.reject { |_, tool| skipped.include?(tool) }.keys
check = sections.map { |section| %(`rails_get_config(section:"#{section}")`) }.join(" and ")
rules = rules.sub(/Check `rails_get_config\(section:"conventions"\)` and `rails_get_config\(section:"gems"\)`/,
                  sections.empty? ? "Check the Gemfile and the code that already does it" : "Check #{check}")
if several
  print rules, "\n", several, "\n" unless memories.any?(&carries)
  puts notes unless notes.empty?
  exit
end

# Claude Code imports nothing from a code block or a code span.
imports_agents = begin
  text = File.binread(File.join(root, "CLAUDE.md")).gsub(/^ {0,3}(```|~~~).*?^ {0,3}\1/m, "").gsub(/`[^`\n]*`/, "")
  text.match?(/(?<!\S)@(?:\.\/)?AGENTS\.md(?!\S)/)
rescue SystemCallError, IOError
  false
end
carried = memories.any?(&carries) ||
          (walked != :down &&
           (carries.(File.join(root, ".claude", "rules", "rails-mcp-tools.md")) ||
            (carries.(File.join(root, "AGENTS.md")) && (imports_agents || memories.empty?))))
print rules unless carried
puts notes unless notes.empty?
