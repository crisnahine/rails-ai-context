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

    def self.names
      DEFINITIONS.keys
    end

    def self.fetch(name)
      DEFINITIONS[name]
    end
  end
end
