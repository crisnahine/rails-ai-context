# frozen_string_literal: true

require "spec_helper"
require "yaml"

# Validates that CursorRulesSerializer output conforms to Cursor's MDC format.
#
# Cursor MDC rules spec (as of 2026):
# - Files: .cursor/rules/*.mdc (flat directory, nested subdirs since v0.47)
# - Frontmatter: YAML with exactly 3 supported fields: description, globs, alwaysApply
# - Four rule types:
#   Type 1 (Always Apply): alwaysApply: true, no globs, description optional
#   Type 2 (Auto Attached): globs present, no description, alwaysApply: false
#   Type 3 (Agent Requested): description present, no globs, alwaysApply: false
#   Type 4 (Manual): no description, no globs, alwaysApply: false
# - Best practice: do NOT combine globs + description (causes dual evaluation overhead)
# - Recommended: <500 lines per file
# - No curly brace glob patterns (unreliable in Cursor)
# - Standard ** recursive glob works
RSpec.describe "Cursor MDC compliance" do
  let(:context) do
    {
      app_name: "TestApp", rails_version: "8.0", ruby_version: "3.4",
      schema: { adapter: "postgresql", total_tables: 12 },
      models: {
        "User" => { associations: [ { type: :has_many, name: :posts } ], validations: [], table_name: "users", scopes: [ "active" ], constants: [] },
        "Post" => { associations: [ { type: :belongs_to, name: :user } ], validations: [], table_name: "posts", scopes: [], constants: [] }
      },
      routes: { total_routes: 45 },
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
      stimulus: {},
      turbo: {}, auth: {}, api: {}, i18n: {}, active_storage: {},
      action_text: {}, assets: {}, engines: {}, multi_database: {},
      design_tokens: {}
    }
  end

  let(:generated_files) do
    Dir.mktmpdir do |dir|
      result = RailsAiContext::Serializers::CursorRulesSerializer.new(context).call(dir)
      rules_dir = File.join(dir, ".cursor", "rules")
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

  def parse_frontmatter(content)
    return nil unless content.start_with?("---")
    parts = content.split("---", 3)
    return nil if parts.size < 3
    YAML.safe_load(parts[1], permitted_classes: [ Symbol ])
  end

  describe "file structure" do
    it "generates only .mdc files" do
      generated_files.each_key do |filename|
        expect(filename).to end_with(".mdc"), "#{filename} does not use .mdc extension"
      end
    end

    it "generates at least project and mcp-tools rules" do
      expect(generated_files.keys).to include("rails-project.mdc", "rails-mcp-tools.mdc")
    end

    it "generates model-specific and controller-specific rules when data exists" do
      expect(generated_files.keys).to include("rails-models.mdc", "rails-controllers.mdc")
    end
  end

  describe "YAML frontmatter" do
    it "every file starts with valid YAML frontmatter" do
      generated_files.each do |filename, file|
        fm = parse_frontmatter(file[:content])
        expect(fm).not_to be_nil, "#{filename} has invalid or missing YAML frontmatter"
      end
    end

    it "frontmatter only uses supported Cursor fields (description, globs, alwaysApply)" do
      supported_fields = %w[description globs alwaysApply]
      generated_files.each do |filename, file|
        fm = parse_frontmatter(file[:content])
        next unless fm.is_a?(Hash)
        fm.each_key do |key|
          expect(supported_fields).to include(key),
            "#{filename} has unsupported frontmatter field: #{key}"
        end
      end
    end

    it "alwaysApply is always a boolean when present" do
      generated_files.each do |filename, file|
        fm = parse_frontmatter(file[:content])
        next unless fm.is_a?(Hash) && fm.key?("alwaysApply")
        expect([ true, false ]).to include(fm["alwaysApply"]),
          "#{filename} has non-boolean alwaysApply: #{fm["alwaysApply"].inspect}"
      end
    end

    it "globs is a string or array of strings when present" do
      generated_files.each do |filename, file|
        fm = parse_frontmatter(file[:content])
        next unless fm.is_a?(Hash) && fm.key?("globs")
        globs = fm["globs"]
        valid = globs.is_a?(String) || (globs.is_a?(Array) && globs.all? { |g| g.is_a?(String) })
        expect(valid).to be(true),
          "#{filename} has invalid globs type: #{globs.inspect}"
      end
    end
  end

  describe "rule type compliance" do
    it "glob-based rules do NOT have description (pure Type 2 auto-attach)" do
      generated_files.each do |filename, file|
        fm = parse_frontmatter(file[:content])
        next unless fm.is_a?(Hash) && fm.key?("globs") && fm["globs"]&.any?
        has_description = fm.key?("description") && fm["description"].is_a?(String) && !fm["description"].empty?
        expect(has_description).to be(false),
          "#{filename} mixes globs + description (Cursor best practice: use one activation mechanism per rule)"
      end
    end

    it "always-apply rules have alwaysApply: true" do
      %w[rails-project.mdc rails-mcp-tools.mdc].each do |filename|
        file = generated_files[filename]
        next unless file
        fm = parse_frontmatter(file[:content])
        expect(fm["alwaysApply"]).to be(true),
          "#{filename} should be alwaysApply: true"
      end
    end

    it "auto-attached rules have alwaysApply: false" do
      %w[rails-models.mdc rails-controllers.mdc rails-ui-patterns.mdc].each do |filename|
        file = generated_files[filename]
        next unless file
        fm = parse_frontmatter(file[:content])
        expect(fm["alwaysApply"]).to be(false),
          "#{filename} should be alwaysApply: false (auto-attached via globs)"
      end
    end
  end

  describe "glob patterns" do
    it "does not use curly brace patterns (unreliable in Cursor)" do
      generated_files.each do |filename, file|
        fm = parse_frontmatter(file[:content])
        next unless fm.is_a?(Hash) && fm.key?("globs")
        globs = Array(fm["globs"])
        globs.each do |glob|
          expect(glob).not_to match(/\{.*\}/),
            "#{filename} uses curly brace glob pattern '#{glob}' which is unreliable in Cursor"
        end
      end
    end

    it "uses standard ** recursive glob syntax" do
      generated_files.each do |filename, file|
        fm = parse_frontmatter(file[:content])
        next unless fm.is_a?(Hash) && fm.key?("globs")
        globs = Array(fm["globs"])
        globs.each do |glob|
          expect(glob).to match(%r{\*\*/}),
            "#{filename} glob '#{glob}' should use ** for recursive matching"
        end
      end
    end

    it "glob strings do not contain spaces after commas" do
      generated_files.each do |filename, file|
        fm = parse_frontmatter(file[:content])
        next unless fm.is_a?(Hash) && fm.key?("globs")
        globs = Array(fm["globs"])
        globs.each do |glob|
          expect(glob).not_to match(/,\s/),
            "#{filename} glob '#{glob}' has spaces after comma (breaks Cursor matching)"
        end
      end
    end
  end

  describe "content limits" do
    it "each file is under 500 lines (Cursor recommendation)" do
      generated_files.each do |filename, file|
        line_count = file[:lines].size
        expect(line_count).to be < 500,
          "#{filename} is #{line_count} lines (Cursor recommends < 500)"
      end
    end
  end

  describe "content quality" do
    it "project rule includes app name" do
      file = generated_files["rails-project.mdc"]
      expect(file[:content]).to include("TestApp")
    end

    it "project rule includes Rails and Ruby versions" do
      file = generated_files["rails-project.mdc"]
      expect(file[:content]).to include("Rails 8.0")
      expect(file[:content]).to include("Ruby 3.4")
    end

    it "project rule references MCP tools file" do
      file = generated_files["rails-project.mdc"]
      expect(file[:content]).to include("rails-mcp-tools.mdc")
    end

    it "models rule includes model names" do
      file = generated_files["rails-models.mdc"]
      expect(file[:content]).to include("User")
      expect(file[:content]).to include("Post")
    end

    it "controllers rule includes controller names" do
      file = generated_files["rails-controllers.mdc"]
      expect(file[:content]).to include("UsersController")
      expect(file[:content]).to include("PostsController")
    end

    it "MCP tools rule includes all 25 tools" do
      file = generated_files["rails-mcp-tools.mdc"]
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
          "MCP tools rule missing tool: #{tool}"
      end
    end

    it "MCP tools rule has task-based workflow" do
      file = generated_files["rails-mcp-tools.mdc"]
      expect(file[:content]).to include("Step-by-step workflows")
    end

    it "MCP tools rule has mandatory language with CLI fallback" do
      file = generated_files["rails-mcp-tools.mdc"]
      expect(file[:content]).to include("MANDATORY")
      expect(file[:content]).to include("NEVER read")
      expect(file[:content]).to include("rails 'ai:tool[")
    end
  end

  describe "skip behavior" do
    it "skips models rule when no models" do
      context[:models] = {}
      Dir.mktmpdir do |dir|
        result = RailsAiContext::Serializers::CursorRulesSerializer.new(context).call(dir)
        expect(result[:written].none? { |f| f.include?("rails-models.mdc") }).to be true
      end
    end

    it "skips controllers rule when no controllers" do
      context[:controllers] = { controllers: {} }
      Dir.mktmpdir do |dir|
        result = RailsAiContext::Serializers::CursorRulesSerializer.new(context).call(dir)
        expect(result[:written].none? { |f| f.include?("rails-controllers.mdc") }).to be true
      end
    end

    it "skips ui-patterns rule when no UI patterns" do
      context[:view_templates] = {}
      Dir.mktmpdir do |dir|
        result = RailsAiContext::Serializers::CursorRulesSerializer.new(context).call(dir)
        expect(result[:written].none? { |f| f.include?("rails-ui-patterns.mdc") }).to be true
      end
    end

    it "skips unchanged files on re-run" do
      Dir.mktmpdir do |dir|
        first = RailsAiContext::Serializers::CursorRulesSerializer.new(context).call(dir)
        second = RailsAiContext::Serializers::CursorRulesSerializer.new(context).call(dir)
        expect(second[:written]).to be_empty
        expect(second[:skipped].size).to eq(first[:written].size)
      end
    end
  end
end
