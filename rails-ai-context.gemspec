# frozen_string_literal: true

require_relative "lib/rails_ai_context/version"

Gem::Specification.new do |spec|
  spec.name          = "rails-ai-context"
  spec.version       = RailsAiContext::VERSION
  spec.authors       = [ "crisnahine" ]
  spec.email         = [ "crisjosephnahine@gmail.com" ]

  spec.summary       = "Auto-expose Rails app structure to AI via MCP (Model Context Protocol) — zero config."
  spec.description   = <<~DESC
    rails-ai-context automatically introspects your Rails application and exposes
    models, routes, schema, jobs, mailers, and conventions through the Model Context
    Protocol (MCP). Works with Claude Code, Cursor, Windsurf, GitHub Copilot, and
    any MCP-compatible AI tool. Zero configuration required.
  DESC

  spec.homepage      = "https://github.com/crisnahine/rails-ai-context"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]      = spec.homepage
  spec.metadata["source_code_uri"]   = spec.homepage
  spec.metadata["changelog_uri"]     = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["bug_tracker_uri"]   = "#{spec.homepage}/issues"
  spec.metadata["funding_uri"]       = "https://github.com/sponsors/crisnahine"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.post_install_message = <<~MSG
    rails-ai-context installed! Quick start:
      rails generate rails_ai_context:install
      rails ai:context         # generate all context files
      rails ai:context:claude  # generate CLAUDE.md only (zsh-friendly)
      rails ai:serve           # start MCP server for Claude Code / Cursor
  MSG

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end

  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = [ "lib" ]

  # Core dependencies
  spec.add_dependency "mcp", "~> 0.8"             # Official MCP Ruby SDK
  spec.add_dependency "railties", ">= 7.1", "< 9.0"
  spec.add_dependency "thor", ">= 1.0", "< 3.0"

  # Dev dependencies
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rubocop", "~> 1.65"
  spec.add_development_dependency "rubocop-rails-omakase", "~> 1.0"
  spec.add_development_dependency "yard", "~> 0.9"
  spec.add_development_dependency "combustion", "~> 1.4" # Test Rails engines in isolation
end
