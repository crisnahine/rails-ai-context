# frozen_string_literal: true

module RailsAiContext
  class Configuration
    PRESETS = {
      standard: %i[schema models routes jobs gems conventions controllers tests migrations],
      full: %i[schema models routes jobs gems conventions stimulus controllers views turbo
               i18n config active_storage action_text auth api tests rake_tasks assets
               devops action_mailbox migrations seeds middleware engines multi_database]
    }.freeze

    # MCP server settings
    attr_accessor :server_name, :server_version

    # Which introspectors to run
    attr_accessor :introspectors

    # Paths to exclude from code search
    attr_accessor :excluded_paths

    # Whether to auto-mount the MCP HTTP endpoint
    attr_accessor :auto_mount

    # HTTP transport settings
    attr_accessor :http_path, :http_bind, :http_port

    # Output directory for generated context files
    attr_accessor :output_dir

    # Models/tables to exclude from introspection
    attr_accessor :excluded_models

    # TTL in seconds for cached introspection (default: 30)
    attr_accessor :cache_ttl

    # Context file generation mode
    # :compact — ≤150 lines CLAUDE.md, references MCP tools for details (default)
    # :full    — current behavior, dumps everything into context files
    attr_accessor :context_mode

    # Max lines for generated CLAUDE.md (only applies in :compact mode)
    attr_accessor :claude_max_lines

    # Max characters for any single MCP tool response (safety net)
    attr_accessor :max_tool_response_chars

    def initialize
      @server_name         = "rails-ai-context"
      @server_version      = RailsAiContext::VERSION
      @introspectors       = PRESETS[:standard].dup
      @excluded_paths      = %w[node_modules tmp log vendor .git]
      @auto_mount          = false
      @http_path           = "/mcp"
      @http_bind           = "127.0.0.1"
      @http_port           = 6029
      @output_dir          = nil # defaults to Rails.root
      @excluded_models     = %w[
        ApplicationRecord
        ActiveStorage::Blob ActiveStorage::Attachment ActiveStorage::VariantRecord
        ActionText::RichText ActionText::EncryptedRichText
        ActionMailbox::InboundEmail ActionMailbox::Record
      ]
      @cache_ttl                = 30
      @context_mode             = :compact
      @claude_max_lines         = 150
      @max_tool_response_chars  = 120_000
    end

    def preset=(name)
      name = name.to_sym
      raise ArgumentError, "Unknown preset: #{name}. Valid presets: #{PRESETS.keys.join(", ")}" unless PRESETS.key?(name)
      @introspectors = PRESETS[name].dup
    end

    def output_dir_for(app)
      @output_dir || app.root.to_s
    end
  end
end
