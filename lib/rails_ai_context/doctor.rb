# frozen_string_literal: true

module RailsAiContext
  # Diagnostic checker that validates the environment and reports
  # AI readiness with pass/warn/fail checks and a readiness score.
  class Doctor
    Check = Data.define(:name, :status, :message, :fix)

    CHECKS = %i[
      check_schema
      check_models
      check_routes
      check_gems
      check_context_files
      check_mcp_buildable
      check_ripgrep
    ].freeze

    attr_reader :app

    def initialize(app = nil)
      @app = app || Rails.application
    end

    def run
      results = CHECKS.map { |check| send(check) }
      score = compute_score(results)
      { checks: results, score: score }
    end

    private

    def check_schema
      schema_path = File.join(app.root, "db/schema.rb")
      if File.exist?(schema_path)
        Check.new(name: "Schema", status: :pass, message: "db/schema.rb found", fix: nil)
      else
        Check.new(name: "Schema", status: :warn, message: "db/schema.rb not found", fix: "Run `rails db:schema:dump` to generate it")
      end
    end

    def check_models
      models_dir = File.join(app.root, "app/models")
      if Dir.exist?(models_dir) && Dir.glob(File.join(models_dir, "**/*.rb")).any?
        count = Dir.glob(File.join(models_dir, "**/*.rb")).size
        Check.new(name: "Models", status: :pass, message: "#{count} model files found", fix: nil)
      else
        Check.new(name: "Models", status: :warn, message: "No model files found in app/models/", fix: "Generate models with `rails generate model`")
      end
    end

    def check_routes
      routes_path = File.join(app.root, "config/routes.rb")
      if File.exist?(routes_path)
        Check.new(name: "Routes", status: :pass, message: "config/routes.rb found", fix: nil)
      else
        Check.new(name: "Routes", status: :fail, message: "config/routes.rb not found", fix: "Ensure you're in a Rails app root directory")
      end
    end

    def check_gems
      lock_path = File.join(app.root, "Gemfile.lock")
      if File.exist?(lock_path)
        Check.new(name: "Gems", status: :pass, message: "Gemfile.lock found", fix: nil)
      else
        Check.new(name: "Gems", status: :warn, message: "Gemfile.lock not found", fix: "Run `bundle install` to generate it")
      end
    end

    def check_context_files
      claude_path = File.join(app.root, "CLAUDE.md")
      if File.exist?(claude_path)
        Check.new(name: "Context files", status: :pass, message: "CLAUDE.md exists", fix: nil)
      else
        Check.new(name: "Context files", status: :warn, message: "No context files generated yet", fix: "Run `rails ai:context` to generate them")
      end
    end

    def check_mcp_buildable
      Server.new(app).build
      Check.new(name: "MCP server", status: :pass, message: "MCP server builds successfully", fix: nil)
    rescue => e
      Check.new(name: "MCP server", status: :fail, message: "MCP server failed to build: #{e.message}", fix: "Check mcp gem installation: `bundle info mcp`")
    end

    def check_ripgrep
      if system("which rg > /dev/null 2>&1")
        Check.new(name: "ripgrep", status: :pass, message: "rg available for code search", fix: nil)
      else
        Check.new(name: "ripgrep", status: :warn, message: "ripgrep not installed (code search will use slower Ruby fallback)", fix: "Install with `brew install ripgrep` or `apt install ripgrep`")
      end
    end

    def compute_score(results)
      total = results.size * 10
      earned = results.sum do |check|
        case check.status
        when :pass then 10
        when :warn then 5
        else 0
        end
      end
      ((earned.to_f / total) * 100).round
    end
  end
end
