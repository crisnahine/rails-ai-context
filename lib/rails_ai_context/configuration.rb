# frozen_string_literal: true

require "yaml"

module RailsAiContext
  class Configuration
    CONFIG_FILENAME = ".rails-ai-context.yml"

    # Keys that require symbol conversion (string → symbol or array of symbols)
    SYMBOL_KEYS = %i[tool_mode preset context_mode live_reload].freeze
    SYMBOL_ARRAY_KEYS = %i[ai_tools introspectors].freeze

    # All YAML-supported keys (explicit allowlist for safety)
    YAML_KEYS = %i[
      ai_tools tool_mode preset context_mode generate_root_files claude_max_lines
      anti_hallucination_rules
      server_name cache_ttl max_tool_response_chars
      live_reload live_reload_debounce auto_mount http_path http_bind http_port
      output_dir skip_tools excluded_models excluded_controllers
      excluded_route_prefixes excluded_filters excluded_middleware excluded_association_names excluded_paths
      sensitive_patterns search_extensions concern_paths frontend_paths
      max_file_size max_test_file_size max_schema_file_size max_view_total_size
      max_view_file_size max_search_results max_validate_files
      query_timeout query_row_limit query_redacted_columns allow_query_in_production
      log_lines introspectors
      hydration_enabled hydration_max_hints
    ].freeze

    # Load configuration from a YAML file, applying values to the current config instance.
    # Only keys present in the YAML are set; absent keys keep their defaults.
    def self.load_from_yaml(path)
      return unless File.exist?(path)

      data = YAML.safe_load_file(path, permitted_classes: [ Symbol ]) || {}
      config = RailsAiContext.configuration

      data.each do |key, value|
        key_sym = key.to_sym
        next unless YAML_KEYS.include?(key_sym)
        next if value.nil?

        value = coerce_value(key_sym, value)
        config.public_send(:"#{key_sym}=", value)
      end

      config
    rescue Psych::SyntaxError, Psych::DisallowedClass => e
      $stderr.puts "[rails-ai-context] WARNING: #{path} has invalid YAML (#{e.message}). Using defaults."
      nil
    end

    # Auto-load config from .rails-ai-context.yml if no initializer configure block ran.
    # Safe to call multiple times (idempotent).
    def self.auto_load!(dir = nil)
      return if RailsAiContext.configured_via_block?

      dir ||= defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : Dir.pwd
      yaml_path = File.join(dir, CONFIG_FILENAME)
      load_from_yaml(yaml_path) if File.exist?(yaml_path)
    end

    def self.coerce_value(key, value)
      if SYMBOL_KEYS.include?(key)
        value.respond_to?(:to_sym) ? value.to_sym : value
      elsif SYMBOL_ARRAY_KEYS.include?(key)
        Array(value).map(&:to_sym)
      else
        value
      end
    end
    private_class_method :coerce_value

    PRESETS = {
      standard: %i[schema models routes jobs gems conventions controllers tests migrations stimulus
                   view_templates config components
                   turbo auth performance i18n],
      full: %i[schema models routes jobs gems conventions stimulus database_stats controllers views view_templates turbo
               i18n config active_storage action_text auth api tests rake_tasks assets
               devops action_mailbox migrations seeds middleware engines multi_database
               components performance frontend_frameworks]
    }.freeze

    # MCP server settings
    attr_accessor :server_name

    def server_version
      RailsAiContext::VERSION
    end

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

    # Whether to generate root-level context files (CLAUDE.md, AGENTS.md, etc.)
    # When false, only generates split rule files (.claude/rules/, .cursor/rules/, etc.)
    attr_accessor :generate_root_files

    # Whether to embed the Anti-Hallucination Protocol section in generated context files.
    # Default: true. Set false to skip the 6-rule verification protocol in CLAUDE.md,
    # AGENTS.md, .claude/rules/, .cursor/rules/, .github/instructions/.
    attr_accessor :anti_hallucination_rules

    # File size limits (bytes) — increase for larger projects
    attr_accessor :max_file_size          # Per-file read limit for tools (default: 2MB)
    attr_accessor :max_test_file_size     # Test file read limit (default: 500KB)
    attr_accessor :max_schema_file_size   # schema.rb / structure.sql parse limit (default: 10MB)
    attr_accessor :max_view_total_size    # Total aggregated view content for template scanning (default: 5MB)
    attr_accessor :max_view_file_size     # Per-view file during aggregation (default: 500KB)
    attr_accessor :max_search_results     # Max search results per call (default: 100)
    attr_accessor :max_validate_files     # Max files per validate call (default: 20)

    # Additional MCP tool classes to register alongside built-in tools
    attr_accessor :custom_tools

    # Built-in tool names to skip (e.g. %w[rails_security_scan rails_query])
    attr_accessor :skip_tools

    # Which AI tools to generate context for (selected during install)
    # nil = all formats, or %i[claude cursor copilot opencode codex]
    attr_accessor :ai_tools

    # Tool invocation mode: :mcp (MCP primary + CLI fallback) or :cli (CLI only)
    attr_accessor :tool_mode

    DEFAULT_EXCLUDED_FILTERS = %w[
      verify_authenticity_token verify_same_origin_request
      turbo_tracking_request_id handle_unverified_request
      mark_for_same_origin_verification
    ].freeze

    DEFAULT_EXCLUDED_MIDDLEWARE = %w[
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
    ].freeze

    DEFAULT_EXCLUDED_CONCERNS = [
      /::Generated/,
      /\A(ActiveRecord|ActiveModel|ActiveSupport|ActionText|ActionMailbox|ActiveStorage)/,
      /\A(ActionDispatch|ActionController|ActionView|AbstractController)/,
      /\A(Devise::Models|Devise::Orm|Bullet::|Turbo::|GlobalID::|Rolify::)/
    ].freeze

    DEFAULT_EXCLUDED_ASSOCIATION_NAMES = %w[
      active_storage_attachments active_storage_blobs
      rich_text_body rich_text_content
      action_mailbox_inbound_emails
      noticed_events noticed_notifications
    ].freeze

    # Filtering — customize what's hidden from AI output
    attr_accessor :excluded_controllers   # Controller classes hidden from listings (e.g. DeviseController)
    attr_accessor :excluded_route_prefixes # Route controller prefixes hidden with app_only (e.g. action_mailbox/)
    attr_accessor :excluded_concerns      # Regex patterns for concerns to hide (e.g. /Devise::Models/)
    attr_accessor :excluded_filters       # Framework filter names hidden from controller output
    attr_accessor :excluded_middleware     # Default middleware hidden from config output
    attr_accessor :excluded_association_names # Framework association names hidden from model output

    # Search and file discovery
    attr_accessor :search_extensions      # File extensions for Ruby fallback search (default: rb,js,erb,yml,yaml,json)
    attr_accessor :concern_paths          # Where to look for concern source files (default: app/models/concerns)

    # Frontend framework detection (optional overrides — auto-detected if nil)
    attr_accessor :frontend_paths         # User-declared frontend dirs (e.g. ["app/frontend", "../web-client"])

    # Database query tool settings (rails_query)
    attr_accessor :query_timeout              # Statement timeout in seconds (default: 5)
    attr_accessor :query_row_limit            # Max rows returned (default: 100, hard cap: 1000)
    attr_accessor :query_redacted_columns     # Column names whose values are redacted in output
    attr_accessor :allow_query_in_production  # Allow rails_query in production (default: false)

    # Log reading settings (rails_read_logs)
    attr_accessor :log_lines                  # Default lines to tail (default: 50)

    # Hydration: inject schema hints into controller/view tool responses
    attr_accessor :hydration_enabled          # Enable/disable hydration (default: true)
    attr_accessor :hydration_max_hints        # Max schema hints per response (default: 5)

    def initialize
      @server_name         = "rails-ai-context"
      @introspectors       = PRESETS[:full].dup
      @excluded_paths      = %w[node_modules tmp log vendor .git doc docs]
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
      @cache_ttl                = 60
      @context_mode             = :compact
      @claude_max_lines         = 150
      @max_tool_response_chars  = 200_000
      @live_reload              = :auto
      @live_reload_debounce     = 1.5
      @generate_root_files      = true
      @anti_hallucination_rules = true
      @max_file_size            = 5_000_000
      @max_test_file_size       = 1_000_000
      @max_schema_file_size     = 10_000_000
      @max_view_total_size      = 10_000_000
      @max_view_file_size       = 1_000_000
      @max_search_results       = 200
      @max_validate_files       = 50
      @excluded_controllers     = %w[DeviseController Devise::OmniauthCallbacksController]
      @excluded_route_prefixes  = %w[action_mailbox/ active_storage/ rails/ conductor/ devise/ turbo/]
      @excluded_concerns        = DEFAULT_EXCLUDED_CONCERNS.dup
      @excluded_filters         = DEFAULT_EXCLUDED_FILTERS.dup
      @excluded_middleware      = DEFAULT_EXCLUDED_MIDDLEWARE.dup
      @excluded_association_names = DEFAULT_EXCLUDED_ASSOCIATION_NAMES.dup
      @custom_tools             = []
      @skip_tools               = []
      @ai_tools                 = nil
      @tool_mode                = :mcp
      @search_extensions        = %w[rb js erb yml yaml json ts tsx vue svelte haml slim]
      @concern_paths            = %w[app/models/concerns app/controllers/concerns]
      @frontend_paths           = nil
      @query_timeout            = 5
      @query_row_limit          = 100
      @query_redacted_columns   = %w[
        password_digest encrypted_password password_hash
        reset_password_token confirmation_token unlock_token
        otp_secret session_data secret_key
        api_key api_secret access_token refresh_token jti
      ]
      @allow_query_in_production = false
      @log_lines                = 50
      @hydration_enabled        = true
      @hydration_max_hints      = 5
    end

    def preset=(name)
      name = name.to_sym
      raise ArgumentError, "Unknown preset: #{name}. Valid presets: #{PRESETS.keys.join(", ")}" unless PRESETS.key?(name)
      @introspectors = PRESETS[name].dup
    end

    def output_dir_for(app)
      @output_dir || app.root.to_s
    end

    def http_port=(value)
      value = value.to_i
      raise ArgumentError, "http_port must be between 1 and 65535 (got #{value})" unless value.between?(1, 65535)
      @http_port = value
    end

    def cache_ttl=(value)
      value = value.to_i
      raise ArgumentError, "cache_ttl must be positive (got #{value})" unless value > 0
      @cache_ttl = value
    end

    def max_tool_response_chars=(value)
      value = value.to_i
      raise ArgumentError, "max_tool_response_chars must be positive (got #{value})" unless value > 0
      @max_tool_response_chars = value
    end

    def query_row_limit=(value)
      value = value.to_i
      raise ArgumentError, "query_row_limit must be between 1 and 1000 (got #{value})" unless value.between?(1, 1000)
      @query_row_limit = value
    end
  end
end
