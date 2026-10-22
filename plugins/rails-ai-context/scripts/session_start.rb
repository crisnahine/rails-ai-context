#!/usr/bin/env ruby
# frozen_string_literal: true

# The rules the generator's context files open with, for the app the server
# serves from here; the installed gem finds it, so the two always agree.
begin
  gem "rails-ai-context"
  require "rails_ai_context/cli/app_root"
  found = RailsAiContext::CLI::AppRoot.resolve(cwd: File.expand_path(ENV["CLAUDE_PROJECT_DIR"] || Dir.pwd))
rescue LoadError, StandardError
  exit
end
root = found.root or exit
exit unless RailsAiContext::CLI::EntryBoot.app_present?(root, allow_source_only: true)

# The app's own switch: an initializer runs after the config file, so its value wins.
# shortcut: a literal assignment only, not a value computed at boot; boot the app here if one is ever reported.
assigned = Dir.glob(File.join(root, "config", "initializers", "**", "*.rb")).sort.filter_map do |path|
  File.binread(path).scan(/^[ \t]*[^#\n]*\.anti_hallucination_rules\s*=\s*(true|false)\b/).flatten.last
rescue SystemCallError, IOError
  nil
end.last
if assigned.nil?
  begin
    require "yaml"
    require "date"
    config = YAML.safe_load_file(File.join(root, ".rails-ai-context.yml"), permitted_classes: [ Symbol, Date, Time ])
    assigned = "false" if config.is_a?(Hash) && [ config["anti_hallucination_rules"], config[:anti_hallucination_rules] ].include?(false)
  rescue StandardError
    nil
  end
end
exit if assigned == "false"

# Claude Code reads a CLAUDE.md below the folder it started in only once a file there is read.
carried = found.walked != :down && %w[CLAUDE.md .claude/rules/rails-mcp-tools.md].any? do |path|
  File.binread(File.join(root, path)).include?("Anti-Hallucination Protocol")
rescue SystemCallError, IOError
  false
end
print File.read(File.join(__dir__, "..", "rules.md")) unless carried
