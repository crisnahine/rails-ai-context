# frozen_string_literal: true

module RailsAiContext
  # Single source of truth for multi-tool presets, run via both
  # `rails 'ai:preset[name]'` (rake task) and `rails-ai-context preset name` (CLI).
  # Every tool call here uses parameters that need no caller-supplied target -
  # tools that require one (analyze_feature needs a feature, migration_advisor
  # needs an action+table, validate needs file paths) are deliberately excluded;
  # in a no-arg preset they would only emit "please provide X" errors.
  module Presets
    DEFINITIONS = {
      "architecture" => {
        desc: "Architecture overview across all layers",
        tools: [
          { name: "onboard", params: {} },
          { name: "dependency_graph", params: {} },
          { name: "performance_check", params: {} }
        ]
      },
      "debugging" => {
        desc: "Diagnose recent issues and inspect live state",
        tools: [
          { name: "read_logs", params: { level: "ERROR", lines: 100 } },
          { name: "review_changes", params: {} },
          { name: "runtime_info", params: {} }
        ]
      },
      "migration" => {
        desc: "Schema overview with migration status and performance check",
        tools: [
          { name: "get_schema", params: { detail: "summary" } },
          { name: "runtime_info", params: { section: "database" } },
          { name: "performance_check", params: {} }
        ]
      }
    }.freeze

    # The one place a typed name becomes a definition key, so the binary's
    # guard and the run accept exactly the same spellings.
    # @return [String, nil] the key, or nil for a name no preset carries
    def self.resolve(name)
      key = name.to_s.strip.downcase
      DEFINITIONS.key?(key) ? key : nil
    end

    # Framing goes to err and tool output to out so a pipe keeps its order;
    # one failing tool costs itself, not the rest of the preset.
    def self.run(name, out: $stdout, err: $stderr)
      key = resolve(name)
      return false unless key

      preset = DEFINITIONS[key]

      err.puts "=" * 60
      err.puts " Preset: #{name} - #{preset[:desc]}"
      err.puts "=" * 60
      err.puts ""
      preset[:tools].each do |tool_spec|
        err.puts "-" * 40
        err.puts "Running: #{tool_spec[:name]}"
        err.puts "-" * 40
        out.puts CLI::ToolRunner.new(tool_spec[:name], tool_spec[:params]).run
        out.puts ""
      rescue => e
        err.puts "  [error] #{tool_spec[:name]}: #{e.message}"
      end
      true
    end

    def self.listing(invocation:)
      lines = [ "Available presets:", "" ]
      DEFINITIONS.each { |key, info| lines << "  #{invocation.call(key)}".ljust(45) + "# #{info[:desc]}" }
      lines.join("\n") + "\n"
    end
  end
end
