# frozen_string_literal: true

module RailsAiContext
  class Configuration
    PRESETS = {
      standard: %i[schema models routes jobs gems conventions controllers tests migrations stimulus view_templates design_tokens config],
      full: %i[schema models routes jobs gems conventions stimulus controllers views view_templates design_tokens turbo
               i18n config active_storage action_text auth api tests rake_tasks assets
               devops action_mailbox migrations seeds middleware engines multi_database]
    }.freeze

    # MCP server settings
    attr_accessor :server_name, :server_version

    # Which introspectors to run
    attr_accessor :introspectors

    # Paths to exclude from code search
    attr_accessor :excluded_paths

    # Sensitive file patterns blocked from search and read tools
    attr_accessor :sensitive_patterns

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

    # Live reload: auto-invalidate MCP tool caches on file changes
    # :auto (default) — enable if `listen` gem is available, skip silently otherwise
    # true  — enable, raise if `listen` gem is missing
    # false — disable entirely
    attr_accessor :live_reload

    # Debounce interval in seconds for live reload file watching
    attr_accessor :live_reload_debounce

    # Whether to generate root-level context files (CLAUDE.md, AGENTS.md, .windsurfrules, etc.)
    # When false, only generates split rule files (.claude/rules/, .cursor/rules/, etc.)
    attr_accessor :generate_root_files

    # File size limits (bytes) — increase for larger projects
    attr_accessor :max_file_size          # Per-file read limit for tools (default: 2MB)
    attr_accessor :max_test_file_size     # Test file read limit (default: 500KB)
    attr_accessor :max_schema_file_size   # schema.rb / structure.sql parse limit (default: 10MB)
    attr_accessor :max_view_total_size    # Total aggregated view content for UI patterns (default: 5MB)
    attr_accessor :max_view_file_size     # Per-view file during aggregation (default: 500KB)
    attr_accessor :max_search_results     # Max search results per call (default: 100)
    attr_accessor :max_validate_files     # Max files per validate call (default: 20)

    # Filtering — customize what's hidden from AI output
    attr_accessor :excluded_controllers   # Controller classes hidden from listings (e.g. DeviseController)
    attr_accessor :excluded_route_prefixes # Route controller prefixes hidden with app_only (e.g. action_mailbox/)
    attr_accessor :excluded_concerns      # Regex patterns for concerns to hide (e.g. /Devise::Models/)
    attr_accessor :excluded_filters       # Framework filter names hidden from controller output
    attr_accessor :excluded_middleware     # Default middleware hidden from config output

    # Search and file discovery
    attr_accessor :search_extensions      # File extensions for Ruby fallback search (default: rb,js,erb,yml,yaml,json)
    attr_accessor :concern_paths          # Where to look for concern source files (default: app/models/concerns)

    def initialize
      @server_name         = "rails-ai-context"
      @server_version      = RailsAiContext::VERSION
      @introspectors       = PRESETS[:standard].dup
      @excluded_paths      = %w[node_modules tmp log vendor .git]
      @sensitive_patterns  = %w[
        .env .env.* config/master.key config/credentials.yml.enc
        config/credentials/*.yml.enc *.pem *.key
      ]
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
      @live_reload              = :auto
      @live_reload_debounce     = 1.5
      @generate_root_files      = true
      @max_file_size            = 2_000_000
      @max_test_file_size       = 500_000
      @max_schema_file_size     = 10_000_000
      @max_view_total_size      = 5_000_000
      @max_view_file_size       = 500_000
      @max_search_results       = 100
      @max_validate_files       = 20
      @excluded_controllers     = %w[DeviseController Devise::OmniauthCallbacksController]
      @excluded_route_prefixes  = %w[action_mailbox/ active_storage/ rails/ conductor/ devise/ turbo/]
      @excluded_concerns        = [
        /::Generated/,
        /\A(ActiveRecord|ActiveModel|ActiveSupport|ActionText|ActionMailbox|ActiveStorage)/,
        /\A(ActionDispatch|ActionController|ActionView|AbstractController)/,
        /\A(Devise::Models|Devise::Orm|Bullet::|Turbo::|GlobalID::|Rolify::)/
      ]
      @excluded_filters         = %w[
        verify_authenticity_token verify_same_origin_request
        turbo_tracking_request_id handle_unverified_request
        mark_for_same_origin_verification
      ]
      @excluded_middleware      = %w[
        Rack::Sendfile ActionDispatch::Static ActionDispatch::Executor
        ActionDispatch::ServerTiming Rack::Runtime
        ActionDispatch::RequestId ActionDispatch::RemoteIp
        Rails::Rack::Logger ActionDispatch::ShowExceptions
        ActionDispatch::DebugExceptions ActionDispatch::Callbacks
        ActionDispatch::Cookies ActionDispatch::Session::CookieStore
        ActionDispatch::Flash ActionDispatch::ContentSecurityPolicy::Middleware
        ActionDispatch::PermissionsPolicy::Middleware ActionDispatch::ActionableExceptions
        Rack::Head Rack::ConditionalGet Rack::ETag Rack::TempfileReaper
        ActiveRecord::Migration::CheckPending ActionDispatch::HostAuthorization
        Rack::MethodOverride ActionDispatch::Session::AbstractSecureStore
      ]
      @search_extensions        = %w[rb js erb yml yaml json ts tsx vue svelte haml slim]
      @concern_paths            = %w[app/models/concerns app/controllers/concerns]
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
