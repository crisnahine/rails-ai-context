# frozen_string_literal: true

require "spec_helper"
require "yaml"

# Validates that Copilot serializer output conforms to GitHub Copilot's instruction format.
#
# GitHub Copilot instructions spec (as of 2026):
# - Root file: .github/copilot-instructions.md — NO YAML frontmatter, plain markdown
# - Path-specific: .github/instructions/*.instructions.md — MUST have applyTo frontmatter
# - Supported frontmatter fields: applyTo (required), excludeAgent, name, description
# - excludeAgent values: "code-review" or "coding-agent"
# - Copilot Code Review: 4,000 character hard limit per instruction file
# - Glob patterns: **/* (all), app/models/**/*.rb, *.{js,ts} — standard glob syntax
# - No order guarantee between matching instruction files
# - Subdirectory organization allowed in .github/instructions/
RSpec.describe "Copilot instructions compliance" do
  let(:context) do
    {
      app_name: "TestApp", rails_version: "8.0", ruby_version: "3.4",
      schema: { adapter: "postgresql", total_tables: 12 },
      models: {
        "User" => { associations: [ { type: :has_many, name: :posts } ], validations: [], table_name: "users", scopes: [ "active" ], constants: [] },
        "Post" => { associations: [ { type: :belongs_to, name: :user } ], validations: [], table_name: "posts", scopes: [], constants: [] }
      },
      routes: { total_routes: 45, by_controller: { "users" => 7, "posts" => 5 } },
      gems: {},
      conventions: {},
      controllers: {
        controllers: {
          "UsersController" => { actions: %w[index show new create edit update destroy] },
          "PostsController" => { actions: %w[index show] }
        }
      },
      view_templates: {
        ui_patterns: {
          components: [
            { type: :button, label: "primary button", classes: "btn btn-primary" },
            { type: :button, label: "danger button", classes: "btn btn-danger" },
            { type: :input, label: "text input", classes: "form-control" }
          ]
        }
      },
      stimulus: {}, turbo: {}, auth: {}, api: {}, i18n: {},
      active_storage: {}, action_text: {}, assets: {}, engines: {},
      multi_database: {}, design_tokens: {}
    }
  end

  def parse_frontmatter(content)
    return nil unless content.start_with?("---")
    parts = content.split("---", 3)
    return nil if parts.size < 3
    YAML.safe_load(parts[1], permitted_classes: [ Symbol ])
  end

  describe "root file (.github/copilot-instructions.md)" do
    let(:root_content) { RailsAiContext::Serializers::CopilotSerializer.new(context).call }

    it "does NOT start with YAML frontmatter" do
      expect(root_content).not_to start_with("---"),
        "copilot-instructions.md must NOT have YAML frontmatter (it's repo-wide by definition)"
    end

    it "is valid markdown content" do
      expect(root_content).to include("# ")
      expect(root_content).to be_a(String)
      expect(root_content.length).to be > 0
    end

    it "includes app name" do
      expect(root_content).to include("TestApp")
    end

    it "includes MCP tool reference section" do
      expect(root_content).to include("MCP")
    end
  end

  describe "instruction files (.github/instructions/*.instructions.md)" do
    let(:generated_files) do
      Dir.mktmpdir do |dir|
        result = RailsAiContext::Serializers::CopilotInstructionsSerializer.new(context).call(dir)
        instructions_dir = File.join(dir, ".github", "instructions")
        files = {}
        result[:written].each do |path|
          filename = File.basename(path)
          files[filename] = {
            path: path,
            content: File.read(path),
            lines: File.readlines(path)
          }
        end
        files
      end
    end

    describe "file naming" do
      it "all files use .instructions.md extension" do
        generated_files.each_key do |filename|
          expect(filename).to end_with(".instructions.md"),
            "#{filename} does not use .instructions.md extension"
        end
      end

      it "filenames are lowercase with hyphens" do
        generated_files.each_key do |filename|
          basename = filename.sub(".instructions.md", "")
          expect(basename).to match(/\A[a-z0-9-]+\z/),
            "#{filename} should be lowercase-hyphenated (got #{basename})"
        end
      end
    end

    describe "YAML frontmatter" do
      it "every file starts with valid YAML frontmatter" do
        generated_files.each do |filename, file|
          fm = parse_frontmatter(file[:content])
          expect(fm).not_to be_nil,
            "#{filename} has invalid or missing YAML frontmatter"
        end
      end

      it "every file has applyTo field" do
        generated_files.each do |filename, file|
          fm = parse_frontmatter(file[:content])
          expect(fm).to be_a(Hash)
          expect(fm).to have_key("applyTo"),
            "#{filename} missing required applyTo frontmatter field"
        end
      end

      it "frontmatter only uses supported Copilot fields" do
        supported_fields = %w[applyTo excludeAgent name description]
        generated_files.each do |filename, file|
          fm = parse_frontmatter(file[:content])
          next unless fm.is_a?(Hash)
          fm.each_key do |key|
            expect(supported_fields).to include(key),
              "#{filename} has unsupported frontmatter field: #{key}"
          end
        end
      end

      it "applyTo is a string" do
        generated_files.each do |filename, file|
          fm = parse_frontmatter(file[:content])
          next unless fm.is_a?(Hash) && fm.key?("applyTo")
          expect(fm["applyTo"]).to be_a(String),
            "#{filename} applyTo should be a string, got #{fm["applyTo"].class}"
        end
      end

      it "excludeAgent uses valid values when present" do
        valid_values = %w[code-review coding-agent]
        generated_files.each do |filename, file|
          fm = parse_frontmatter(file[:content])
          next unless fm.is_a?(Hash) && fm.key?("excludeAgent")
          expect(valid_values).to include(fm["excludeAgent"]),
            "#{filename} has invalid excludeAgent: #{fm["excludeAgent"]} (valid: #{valid_values.join(', ')})"
        end
      end
    end

    describe "glob patterns" do
      it "all applyTo values are valid glob patterns" do
        generated_files.each do |filename, file|
          fm = parse_frontmatter(file[:content])
          next unless fm.is_a?(Hash) && fm["applyTo"]
          pattern = fm["applyTo"]
          # Should be a glob-like pattern, not empty
          expect(pattern.length).to be > 0,
            "#{filename} has empty applyTo"
        end
      end

      it "path-specific files use recursive ** globs" do
        generated_files.each do |filename, file|
          fm = parse_frontmatter(file[:content])
          next unless fm.is_a?(Hash) && fm["applyTo"]
          expect(fm["applyTo"]).to include("**"),
            "#{filename} applyTo '#{fm["applyTo"]}' should use ** for recursive matching"
        end
      end
    end

    describe "agent-specific exclusions" do
      it "MCP tools file excludes code-review agent" do
        file = generated_files["rails-mcp-tools.instructions.md"]
        expect(file).not_to be_nil, "MCP tools instruction file not generated"
        fm = parse_frontmatter(file[:content])
        expect(fm["excludeAgent"]).to eq("code-review"),
          "MCP tools file should exclude code-review (code review can't invoke MCP tools)"
      end

      it "context file does NOT exclude any agent" do
        file = generated_files["rails-context.instructions.md"]
        expect(file).not_to be_nil
        fm = parse_frontmatter(file[:content])
        expect(fm).not_to have_key("excludeAgent"),
          "Context overview is useful for both coding agent and code review"
      end

      it "models file does NOT exclude any agent" do
        file = generated_files["rails-models.instructions.md"]
        expect(file).not_to be_nil
        fm = parse_frontmatter(file[:content])
        expect(fm).not_to have_key("excludeAgent"),
          "Models reference is useful for code review"
      end
    end

    describe "content quality" do
      it "context file includes app name" do
        file = generated_files["rails-context.instructions.md"]
        expect(file[:content]).to include("TestApp")
      end

      it "models file includes model names" do
        file = generated_files["rails-models.instructions.md"]
        expect(file[:content]).to include("User")
        expect(file[:content]).to include("Post")
      end

      it "controllers file includes controller names" do
        file = generated_files["rails-controllers.instructions.md"]
        expect(file[:content]).to include("UsersController")
        expect(file[:content]).to include("PostsController")
      end

      it "MCP tools file includes all 25 tools" do
        file = generated_files["rails-mcp-tools.instructions.md"]
        content = file[:content]
        %w[
          rails_get_schema rails_get_model_details rails_get_routes
          rails_get_controllers rails_search_code rails_validate
          rails_analyze_feature rails_get_context rails_get_view
          rails_get_stimulus rails_get_design_system rails_get_test_info
          rails_get_conventions rails_get_concern rails_get_callbacks
          rails_get_edit_context rails_get_service_pattern rails_get_job_pattern
          rails_get_env rails_get_partial_interface rails_get_turbo_map
          rails_get_helper_methods rails_get_config rails_get_gems
          rails_security_scan
        ].each do |tool|
          expect(content).to include(tool),
            "MCP tools file missing tool: #{tool}"
        end
      end

      it "MCP tools file has task-based workflow" do
        file = generated_files["rails-mcp-tools.instructions.md"]
        expect(file[:content]).to include("What Are You Trying to Do?")
      end

      it "MCP tools file has graceful fallback language" do
        file = generated_files["rails-mcp-tools.instructions.md"]
        expect(file[:content]).to include("not available")
        expect(file[:content]).to include("Prefer MCP tools")
      end
    end

    describe "skip behavior" do
      it "skips models file when no models" do
        context[:models] = {}
        Dir.mktmpdir do |dir|
          result = RailsAiContext::Serializers::CopilotInstructionsSerializer.new(context).call(dir)
          expect(result[:written].none? { |f| f.include?("rails-models") }).to be true
        end
      end

      it "skips controllers file when no controllers" do
        context[:controllers] = { controllers: {} }
        Dir.mktmpdir do |dir|
          result = RailsAiContext::Serializers::CopilotInstructionsSerializer.new(context).call(dir)
          expect(result[:written].none? { |f| f.include?("rails-controllers") }).to be true
        end
      end

      it "skips ui-patterns file when no UI patterns" do
        context[:view_templates] = {}
        Dir.mktmpdir do |dir|
          result = RailsAiContext::Serializers::CopilotInstructionsSerializer.new(context).call(dir)
          expect(result[:written].none? { |f| f.include?("rails-ui-patterns") }).to be true
        end
      end

      it "skips unchanged files on re-run" do
        Dir.mktmpdir do |dir|
          first = RailsAiContext::Serializers::CopilotInstructionsSerializer.new(context).call(dir)
          second = RailsAiContext::Serializers::CopilotInstructionsSerializer.new(context).call(dir)
          expect(second[:written]).to be_empty
          expect(second[:skipped].size).to eq(first[:written].size)
        end
      end
    end
  end
end
