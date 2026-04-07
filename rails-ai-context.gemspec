# frozen_string_literal: true

require_relative "lib/rails_ai_context/version"

Gem::Specification.new do |spec|
  spec.name          = "rails-ai-context"
  spec.version       = RailsAiContext::VERSION
  spec.authors       = [ "crisnahine" ]
  spec.email         = [ "crisjosephnahine@gmail.com" ]

  spec.summary       = "Stop AI from guessing your Rails app. 38 tools give coding agents ground truth — schema, models, routes, conventions — on demand. MCP or CLI."
  spec.description   = <<~DESC
    rails-ai-context turns your running Rails app into the source of truth for AI
    coding assistants. Instead of guessing from training data or stale file reads,
    agents query 38 live tools (via MCP server or CLI) to get your actual schema,
    associations, routes, inherited filters, conventions, and test patterns.
    Semantic validation catches cross-file errors (wrong columns, missing partials,
    broken routes) before code runs — so AI writes correct code on the first try.
    Auto-generates context files for Claude Code, Cursor, GitHub Copilot, and
    OpenCode. Works standalone or in-Gemfile.
  DESC

  spec.homepage      = "https://github.com/crisnahine/rails-ai-context"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]      = spec.homepage
  spec.metadata["source_code_uri"]   = "#{spec.homepage}/tree/main"
  spec.metadata["changelog_uri"]     = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["bug_tracker_uri"]   = "#{spec.homepage}/issues"
  spec.metadata["funding_uri"]       = "https://github.com/sponsors/crisnahine"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.post_install_message = <<~MSG
    rails-ai-context installed!

    Standalone (no Gemfile entry needed):
      cd your-rails-app
      rails-ai-context init           # interactive setup
      rails-ai-context serve          # start MCP server

    Or add to Gemfile:
      gem "rails-ai-context", group: :development
      rails generate rails_ai_context:install
      rails ai:serve
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
  spec.add_dependency "mcp", ">= 0.8", "< 2.0"    # Official MCP Ruby SDK (0.8–0.10+ compatible)
  spec.add_dependency "railties", ">= 7.1", "< 9.0"
  spec.add_dependency "thor", ">= 1.0", "< 3.0"
  spec.add_dependency "zeitwerk", "~> 2.6"         # Autoloading

  # AST foundation (Phase 1: Ground Truth Engine)
  spec.add_dependency "prism", ">= 0.28"           # Ruby parser — stdlib in 3.3+, gem for 3.2
  spec.add_dependency "concurrent-ruby", ">= 1.2"  # Thread-safe AST cache via Concurrent::Map

  # Dev dependencies
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rubocop", "~> 1.65"
  spec.add_development_dependency "rubocop-rails-omakase", "~> 1.0"
  spec.add_development_dependency "combustion", "~> 1.4" # Test Rails engines in isolation
end
