# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "yaml"

RSpec.describe RailsAiContext::Configuration, "YAML loading" do
  let(:config) { RailsAiContext.configuration }

  before do
    # Reset configuration state for each test
    RailsAiContext.configuration = RailsAiContext::Configuration.new
  end

  after do
    # Restore clean state so other specs don't see leaked config
    RailsAiContext.configuration = RailsAiContext::Configuration.new
  end

  describe ".load_from_yaml" do
    it "loads ai_tools and tool_mode from YAML" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({
          "ai_tools" => %w[claude cursor],
          "tool_mode" => "cli"
        }))

        RailsAiContext::Configuration.load_from_yaml(yaml_path)

        expect(config.ai_tools).to eq(%i[claude cursor])
        expect(config.tool_mode).to eq(:cli)
      end
    end

    it "converts preset and context_mode to symbols" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({
          "preset" => "standard",
          "context_mode" => "full"
        }))

        RailsAiContext::Configuration.load_from_yaml(yaml_path)

        expect(config.introspectors).to eq(RailsAiContext::Configuration::PRESETS[:standard])
        expect(config.context_mode).to eq(:full)
      end
    end

    it "sets scalar values correctly" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({
          "cache_ttl" => 120,
          "claude_max_lines" => 200,
          "http_port" => 8080,
          "max_file_size" => 10_000_000,
          "query_timeout" => 10,
          "log_lines" => 100,
          "auto_mount" => true,
          "generate_root_files" => false,
          "anti_hallucination_rules" => false
        }))

        RailsAiContext::Configuration.load_from_yaml(yaml_path)

        expect(config.cache_ttl).to eq(120)
        expect(config.claude_max_lines).to eq(200)
        expect(config.http_port).to eq(8080)
        expect(config.max_file_size).to eq(10_000_000)
        expect(config.query_timeout).to eq(10)
        expect(config.log_lines).to eq(100)
        expect(config.auto_mount).to eq(true)
        expect(config.generate_root_files).to eq(false)
        expect(config.anti_hallucination_rules).to eq(false)
      end
    end

    it "sets array values correctly" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({
          "skip_tools" => %w[rails_security_scan rails_query],
          "excluded_models" => %w[AdminUser InternalThing],
          "search_extensions" => %w[rb js ts]
        }))

        RailsAiContext::Configuration.load_from_yaml(yaml_path)

        expect(config.skip_tools).to eq(%w[rails_security_scan rails_query])
        expect(config.excluded_models).to eq(%w[AdminUser InternalThing])
        expect(config.search_extensions).to eq(%w[rb js ts])
      end
    end

    it "sets excluded_association_names from YAML" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({
          "excluded_association_names" => %w[custom_assoc other_assoc]
        }))

        RailsAiContext::Configuration.load_from_yaml(yaml_path)

        expect(config.excluded_association_names).to eq(%w[custom_assoc other_assoc])
      end
    end

    it "ignores unknown keys" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({
          "ai_tools" => %w[claude],
          "not_a_real_key" => "should be ignored",
          "custom_tools" => "also ignored"
        }))

        expect { RailsAiContext::Configuration.load_from_yaml(yaml_path) }.not_to raise_error
        expect(config.ai_tools).to eq(%i[claude])
      end
    end

    it "skips nil values (preserves defaults)" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({
          "ai_tools" => %w[claude],
          "cache_ttl" => nil
        }))

        RailsAiContext::Configuration.load_from_yaml(yaml_path)

        expect(config.ai_tools).to eq(%i[claude])
        expect(config.cache_ttl).to eq(60) # default
      end
    end

    it "warns on a bad value and keeps the default, like bad syntax" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({ "http_port" => 0, "cache_ttl" => 120 }))

        captured = StringIO.new
        orig_err = $stderr
        begin
          $stderr = captured
          expect { RailsAiContext::Configuration.load_from_yaml(yaml_path) }.not_to raise_error
        ensure
          $stderr = orig_err
        end

        expect(captured.string).to include("http_port")
        config = RailsAiContext.configuration
        expect(config.http_port).not_to eq(0)
        expect(config.cache_ttl).to eq(120)
      end
    end

    it "keeps the default on an out-of-range query_row_limit" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({ "query_row_limit" => 5000 }))

        captured = StringIO.new
        orig_err = $stderr
        begin
          $stderr = captured
          RailsAiContext::Configuration.load_from_yaml(yaml_path)
        ensure
          $stderr = orig_err
        end

        expect(captured.string).to include("query_row_limit")
        expect(RailsAiContext.configuration.query_row_limit).not_to eq(5000)
      end
    end

    it "returns nil for nonexistent file" do
      result = RailsAiContext::Configuration.load_from_yaml("/nonexistent/.rails-ai-context.yml")
      expect(result).to be_nil
    end

    it "handles corrupted YAML gracefully" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, "this is not: [valid: yaml: {{{{")

        result = RailsAiContext::Configuration.load_from_yaml(yaml_path)
        expect(result).to be_nil
        # Defaults should remain intact
        expect(config.tool_mode).to eq(:mcp)
        expect(config.cache_ttl).to eq(60)
      end
    end

    it "handles empty YAML file" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, "")

        expect { RailsAiContext::Configuration.load_from_yaml(yaml_path) }.not_to raise_error
      end
    end

    it "preserves defaults for absent keys" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({ "ai_tools" => %w[claude] }))

        RailsAiContext::Configuration.load_from_yaml(yaml_path)

        # Only ai_tools changed; everything else stays at defaults
        expect(config.ai_tools).to eq(%i[claude])
        expect(config.cache_ttl).to eq(60)
        expect(config.tool_mode).to eq(:mcp)
        expect(config.context_mode).to eq(:compact)
        expect(config.max_file_size).to eq(5_000_000)
        expect(config.introspectors).to eq(RailsAiContext::Configuration::PRESETS[:full])
      end
    end

    it "converts live_reload string to symbol" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({ "live_reload" => "auto" }))

        RailsAiContext::Configuration.load_from_yaml(yaml_path)
        expect(config.live_reload).to eq(:auto)
      end
    end

    it "handles live_reload: true (YAML boolean, not string)" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({ "live_reload" => true }))

        RailsAiContext::Configuration.load_from_yaml(yaml_path)
        expect(config.live_reload).to eq(true)
      end
    end

    it "handles live_reload: false (YAML boolean, not string)" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({ "live_reload" => false }))

        RailsAiContext::Configuration.load_from_yaml(yaml_path)
        expect(config.live_reload).to eq(false)
      end
    end

    it "loads hydration config from YAML" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({
          "hydration_enabled" => false,
          "hydration_max_hints" => 10
        }))

        RailsAiContext::Configuration.load_from_yaml(yaml_path)

        expect(config.hydration_enabled).to eq(false)
        expect(config.hydration_max_hints).to eq(10)
      end
    end

    it "preserves hydration defaults when not specified in YAML" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({ "cache_ttl" => 120 }))

        RailsAiContext::Configuration.load_from_yaml(yaml_path)

        expect(config.hydration_enabled).to eq(true)
        expect(config.hydration_max_hints).to eq(5)
      end
    end

    it "converts introspectors array to symbols" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({ "introspectors" => %w[schema models routes] }))

        RailsAiContext::Configuration.load_from_yaml(yaml_path)
        expect(config.introspectors).to eq(%i[schema models routes])
      end
    end

    it "loads extra_app_paths as an array of strings" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({
          "extra_app_paths" => %w[src vendor/internal]
        }))

        RailsAiContext::Configuration.load_from_yaml(yaml_path)

        expect(config.extra_app_paths).to eq(%w[src vendor/internal])
      end
    end

    it "defaults extra_app_paths to an empty array" do
      expect(RailsAiContext::Configuration.new.extra_app_paths).to eq([])
    end
  end

  describe ".auto_load!" do
    # Every entry point loads the file; the keys a block assigned are what it
    # keeps, so the same merge holds after the app's initializers have run.
    it "keeps a key the block assigned and takes the rest from the file" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({ "tool_mode" => "cli", "server_name" => "from-yaml" }))

        RailsAiContext.configure { |c| c.tool_mode = :mcp }

        RailsAiContext::Configuration.auto_load!(dir)

        expect(config.tool_mode).to eq(:mcp)
        expect(config.server_name).to eq("from-yaml")
      end
    end

    it "loads YAML when no configure block ran" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({ "tool_mode" => "cli" }))

        RailsAiContext::Configuration.auto_load!(dir)

        expect(config.tool_mode).to eq(:cli)
      end
    end

    it "uses defaults when no config file exists" do
      Dir.mktmpdir do |dir|
        RailsAiContext::Configuration.auto_load!(dir)

        expect(config.tool_mode).to eq(:mcp)
        expect(config.cache_ttl).to eq(60)
        expect(config.ai_tools).to be_nil
      end
    end

    it "is idempotent" do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, ".rails-ai-context.yml")
        File.write(yaml_path, YAML.dump({ "cache_ttl" => 120 }))

        RailsAiContext::Configuration.auto_load!(dir)
        RailsAiContext::Configuration.auto_load!(dir)

        expect(config.cache_ttl).to eq(120)
      end
    end

    # `config.skip_tools << "..."` in an initializer is the idiom the gem's own
    # remedy strings taught, and it survives only because the file is applied
    # once, before those initializers run.
    it "leaves an in-place edit alone on a second call" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".rails-ai-context.yml"),
                   YAML.dump({ "skip_tools" => [ "rails_console" ] }))

        RailsAiContext::Configuration.auto_load!(dir)
        config.skip_tools << "rails_query"
        RailsAiContext::Configuration.auto_load!(dir)

        expect(config.skip_tools).to contain_exactly("rails_console", "rails_query")
      end
    end

    it "reads the file again for a fresh configuration" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".rails-ai-context.yml"), YAML.dump({ "cache_ttl" => 120 }))

        RailsAiContext::Configuration.auto_load!(dir)
        RailsAiContext.configuration = RailsAiContext::Configuration.new
        RailsAiContext::Configuration.auto_load!(dir)

        expect(RailsAiContext.configuration.cache_ttl).to eq(120)
      end
    end

    # The file is read once, at boot: a config file that appears mid-process is
    # not picked up by a later call.
    it "does not read a file written after the first call" do
      Dir.mktmpdir do |dir|
        RailsAiContext::Configuration.auto_load!(dir)
        File.write(File.join(dir, ".rails-ai-context.yml"), YAML.dump({ "cache_ttl" => 120 }))
        RailsAiContext::Configuration.auto_load!(dir)

        expect(config.cache_ttl).to eq(60)
      end
    end
  end

  describe ".load_config_file!" do
    # Precedence is a merge: the YAML is the base over the defaults and a
    # configure block overrides it key by key, so a key the block never
    # mentions keeps what the file said.
    it "leaves a key the block never set applied" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".rails-ai-context.yml"),
                   YAML.dump({ "skip_tools" => [ "rails_query" ], "server_name" => "from-yaml" }))

        RailsAiContext::Configuration.load_config_file!(dir)
        RailsAiContext.configure { |c| c.server_name = "from-block" }

        expect(config.skip_tools).to eq([ "rails_query" ])
        expect(config.server_name).to eq("from-block")
      end
    end

    it "applies the YAML even when a configure block has already run" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".rails-ai-context.yml"),
                   YAML.dump({ "skip_tools" => [ "rails_query" ] }))

        RailsAiContext.configure { |c| c.server_name = "from-block" }
        RailsAiContext::Configuration.load_config_file!(dir)

        expect(config.skip_tools).to eq([ "rails_query" ])
      end
    end

    # The engine loads the file on every in-Gemfile boot, and File.exist? is
    # true for a directory or a file the process cannot read.
    it "keeps the defaults when a directory sits at the config file's path" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".rails-ai-context.yml"))

        expect { RailsAiContext::Configuration.load_config_file!(dir) }.not_to raise_error
        expect(config.tool_mode).to eq(:mcp)
      end
    end

    # A block in config/application.rb or config/environments/*.rb runs before
    # the engine's file load, so precedence cannot depend on placement.
    it "keeps a key the block set even when the file loads afterwards" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".rails-ai-context.yml"),
                   YAML.dump({ "skip_tools" => [ "rails_query" ], "server_name" => "from-yaml" }))

        RailsAiContext.configure { |c| c.skip_tools = [ "rails_console" ] }
        RailsAiContext::Configuration.load_config_file!(dir)

        expect(config.skip_tools).to eq([ "rails_console" ])
        expect(config.server_name).to eq("from-yaml")
      end
    end
  end

  describe "#ai_tools record fallback" do
    it "answers from SelectionRecord when the configure block did not set it" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".rails-ai-context.yml"), YAML.dump({ "ai_tools" => %w[claude cursor] }))

        config = RailsAiContext::Configuration.new
        config.app_root = dir
        expect(config.ai_tools).to eq(%i[claude cursor])
      end
    end

    it "stays nil when nothing was recorded" do
      Dir.mktmpdir do |dir|
        config = RailsAiContext::Configuration.new
        config.app_root = dir
        expect(config.ai_tools).to be_nil
      end
    end

    it "prefers the explicit assignment" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".rails-ai-context.yml"), YAML.dump({ "ai_tools" => %w[claude] }))

        config = RailsAiContext::Configuration.new
        config.app_root = dir
        config.ai_tools = %i[codex]
        expect(config.ai_tools).to eq(%i[codex])
      end
    end
  end
end
