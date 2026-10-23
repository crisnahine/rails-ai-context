#!/usr/bin/env ruby
# frozen_string_literal: true

# The rules the generator's context files open with, for the app the server
# serves from here; the installed gem finds it, so the two always agree.
require_relative "gem_requirement"
requirement = Gem::Requirement.new(RailsAiContextPlugin::GEM_REQUIREMENT)
start = File.expand_path(ENV["CLAUDE_PROJECT_DIR"] || Dir.pwd)
begin
  # Activated as serve.rb activates it, so the rules come only where the server starts.
  Gem.activate_bin_path("rails-ai-context", "rails-ai-context", requirement.to_s)
  # Bundler's activate_bin_path drops the requirement, and the server refuses an older copy.
  spec = Gem.loaded_specs["rails-ai-context"]
  exit if spec && !requirement.satisfied_by?(spec.version)
  require "rails_ai_context/cli/app_root"
  require "rails_ai_context/gem_lock"
  found = RailsAiContext::CLI::AppRoot.resolve(cwd: start)
  root = found.root or exit
  exit unless RailsAiContext::CLI::EntryBoot.app_present?(root, allow_source_only: true)
  # The server hands such an app to its bundle's copy, whose tools the rules then
  # name. Most apps never lock the gem, and reading a lock whole takes a second.
  # shortcut: repeats AppRoot.lock_names_gem?, which the 5.35.1 floor lacks; call it once the requirement reaches a release that has it.
  named = ENV["BUNDLE_GEMFILE"].to_s
  lockfile = if named.empty? then RailsAiContext::GemLock.bundle(root).lockfile
  elsif File.basename(named) == "gems.rb" then File.join(File.dirname(named), "gems.locked")
  else "#{named}.lock"
  end
  names_gem = begin
    lockfile && File.file?(lockfile) && File.read(lockfile).include?("rails-ai-context")
  rescue SystemCallError, IOError
    false
  end
  if names_gem
    handoff = RailsAiContext::CLI::AppRoot.bundled_handoff(root)
    exit if handoff && !requirement.satisfied_by?(Gem::Version.new(handoff.version)) &&
            RailsAiContext::CLI::AppRoot.bundle_ready?(handoff.env, root)
  end
# A Ruby too old for the gem's own code fails to parse it, which no StandardError covers.
rescue ScriptError, StandardError
  exit
end

# The app's settings as its boot applies them: a configure block in application.rb or the environment's
# file runs before the config file loads and an initializer after it, so the last literal wins.
# shortcut: a literal that ends its statement only, not a value computed at boot; boot the app here if one is ever reported.
environment = [ ENV["RAILS_ENV"], ENV["RACK_ENV"] ].find { |name| !name.to_s.empty? } || "development"
initializers = File.join(root, "config", "initializers")
sources = [ File.join(root, "config", "application.rb"), File.join(root, "config", "environments", "#{environment}.rb"),
            *Dir.glob("**/*.rb", base: initializers).sort.map { |path| File.join(initializers, path) } ].filter_map do |path|
  File.binread(path).gsub("\r\n", "\n").gsub(/^=begin\b.*?^=end\b/m, "")
rescue SystemCallError, IOError
  nil
end
literal = ->(key, value) { sources.flat_map { |text| text.scan(/^[^#\n]*\.#{key}\s*=\s*(#{value})[ \t]*(?:[#;}]|\bend\b|$)/) }.flatten.last }
file = begin
  require "yaml"
  require "date"
  YAML.safe_load_file(File.join(root, ".rails-ai-context.yml"), permitted_classes: [ Symbol, Date, Time ], aliases: true)
rescue StandardError
  nil
end
file = {} unless file.is_a?(Hash)

switch = literal.("anti_hallucination_rules", "true|false|nil")
exit if %w[false nil].include?(switch)
exit if switch.nil? && [ file["anti_hallucination_rules"], file[:anti_hallucination_rules] ].include?(false)

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
skipped |= appended.flat_map { |op, span| names.(%w[+= |=].include?(op) ? span : span.gsub(/%[iI](?:\[[^\]]*\]|\([^)]*\))|:\w+/, "")) }
rules = File.read(File.join(__dir__, "..", "rules.md"))
# Rule 3 names a rails_get_config section only where skip_tools leaves it on, as the generator writes it.
sections = { "conventions" => "rails_get_conventions", "gems" => "rails_get_gems" }.reject { |_, tool| skipped.include?(tool) }.keys
check = sections.map { |section| %(`rails_get_config(section:"#{section}")`) }.join(" and ")
rules = rules.sub(/Check `rails_get_config\(section:"conventions"\)` and `rails_get_config\(section:"gems"\)`/,
                  sections.empty? ? "Check the Gemfile and the code that already does it" : "Check #{check}")

# What Claude Code loads at launch for a session started here: the app's CLAUDE.md and rules file, and its
# AGENTS.md where CLAUDE.md imports it or none is on the way up. One below loads only once a file there is read.
# shortcut: Claude Code's default Project instructions setting; read its pluginConfigs if a changed one is reported.
carries = lambda do |path|
  File.binread(path).include?("Anti-Hallucination Protocol")
rescue SystemCallError, IOError
  false
end
# Claude Code imports nothing from a code block or a code span.
imports_agents = begin
  text = File.binread(File.join(root, "CLAUDE.md")).gsub(/^ {0,3}(```|~~~).*?^ {0,3}\1/m, "").gsub(/`[^`\n]*`/, "")
  text.match?(/(?<!\S)@(?:\.\/)?AGENTS\.md(?!\S)/)
rescue SystemCallError, IOError
  false
end
# The user's own memory, under CLAUDE_CONFIG_DIR as Claude Code resolves it from here, else
# under the home folder, which on Windows is %USERPROFILE%, as Ruby takes it only without HOME.
user_memory = begin
  profile = ENV["USERPROFILE"].to_s
  home = Gem.win_platform? && !profile.empty? ? profile : Dir.home
  File.join(ENV.key?("CLAUDE_CONFIG_DIR") ? File.absolute_path(ENV["CLAUDE_CONFIG_DIR"]) : File.join(home, ".claude"), "CLAUDE.md")
rescue ArgumentError
  nil
end
# The start folder up to the filesystem root, which Claude Code's walk stops short of.
folders = [ start ]
folders << File.dirname(folders.last) until File.dirname(folders.last) == folders.last
folders.pop
memories = folders.flat_map { |folder| %w[CLAUDE.md .claude/CLAUDE.md CLAUDE.local.md].map { |name| File.join(folder, name) } }
                  .select { |path| File.exist?(path) && !(user_memory && File.identical?(path, user_memory)) }
carried = memories.any?(&carries) ||
          (found.walked != :down &&
           (carries.(File.join(root, ".claude", "rules", "rails-mcp-tools.md")) ||
            (carries.(File.join(root, "AGENTS.md")) && (imports_agents || memories.empty?))))
print rules unless carried
