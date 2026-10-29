# frozen_string_literal: true

require "yaml"
require "date"

module RailsAiContext
  class Configuration
    CONFIG_FILENAME = ".rails-ai-context.yml"

    # Keys that require symbol conversion (string → symbol or array of symbols)
    SYMBOL_KEYS = %i[tool_mode preset context_mode].freeze

    CONTEXT_MODES = %i[compact full].freeze
    TOOL_MODES = %i[mcp cli].freeze
    SYMBOL_ARRAY_KEYS = %i[ai_tools introspectors].freeze

    # The shape each key's value takes, so a wrong one warns from the file instead of failing a tool later.
    LIST_KEYS = %i[
      excluded_models excluded_controllers excluded_route_prefixes excluded_filters excluded_middleware
      excluded_association_names excluded_paths excluded_concerns sensitive_patterns search_extensions
      concern_paths frontend_paths extra_app_paths query_redacted_columns query_allowed_columns
    ].freeze
    INTEGER_KEYS = %i[
      claude_max_lines cache_ttl max_tool_response_chars http_port max_file_size max_test_file_size
      max_schema_file_size max_view_total_size max_view_file_size max_search_results max_validate_files
      query_row_limit log_lines hydration_max_hints
    ].freeze

    # All YAML-supported keys (explicit allowlist for safety)
    YAML_KEYS = %i[
      ai_tools tool_mode preset context_mode context_files generate_root_files claude_max_lines
      anti_hallucination_rules report_issue_line
      server_name cache_ttl max_tool_response_chars
      live_reload live_reload_debounce auto_mount http_path http_bind http_port allow_http_in_production
      output_dir skip_tools excluded_models excluded_controllers
      excluded_route_prefixes excluded_filters excluded_middleware excluded_association_names excluded_paths
      excluded_concerns
      sensitive_patterns search_extensions concern_paths frontend_paths extra_app_paths
      max_file_size max_test_file_size max_schema_file_size max_view_total_size
      max_view_file_size max_search_results max_validate_files
      query_timeout query_row_limit query_redacted_columns query_allowed_columns allow_query_in_production
      log_lines introspectors
      hydration_enabled hydration_max_hints
      instrumentation_include_arguments
    ].freeze

    # Dates and times because a hand-added `generated_at:` is ordinary in a
    # config file, and a class outside this list costs the whole file, not the
    # one key.
    PERMITTED_YAML_CLASSES = [ Symbol, Date, Time ].freeze

    # Not config, and not a typo either: an annotation the installer round-trips.
    IGNORED_YAML_KEYS = %i[generated_at].freeze

    # Real options a YAML file cannot carry, because their value is a Ruby
    # object. Reported as such, so nobody hunts for a misspelling.
    RUBY_ONLY_KEYS = %i[custom_tools].freeze

    # The lists that keep a file or tool out of reach, the YAML's entries kept beside the code's so no tier serves what another withholds.
    UNION_KEYS = %i[sensitive_patterns excluded_paths skip_tools].freeze

    # Load configuration from a YAML file, applying values to `config`.
    # Only keys present in the YAML are set; absent keys keep their defaults.
    def self.load_from_yaml(path, config = RailsAiContext.configuration)
      return unless File.exist?(path)

      data, error = read_yaml(path)
      return $stderr.puts("[rails-ai-context] WARNING: #{yaml_problem(path, error)}") if error

      apply_yaml(data, path, config)
    end

    # @return [Array(Object, Exception)] the file's data, or nil and the error that kept it from being read
    def self.read_yaml(path)
      [ YAML.safe_load_file(path, permitted_classes: PERMITTED_YAML_CLASSES, aliases: true) || {}, nil ]
    rescue Psych::Exception, SystemCallError => e
      # File.exist? is true for a directory and for a file the process cannot
      # read, and this runs inside an engine initializer on every boot.
      [ nil, e ]
    end

    def self.yaml_problem(path, error)
      error.is_a?(SystemCallError) ? "#{path} could not be read (#{error.message}). Using defaults." : "#{path} has invalid YAML (#{error.message}). Using defaults."
    end

    def self.apply_yaml(data, path, config)
      return $stderr.puts("[rails-ai-context] WARNING: #{path}: the file holds no `key: value` settings. Ignored.") unless data.is_a?(Hash)

      defaults = new
      data.each do |key, value|
        # A permitted Date or Time key has no `to_sym`, and a NoMethodError
        # here escapes into app boot.
        key_sym = key.to_s.to_sym
        next if IGNORED_YAML_KEYS.include?(key_sym)
        if RUBY_ONLY_KEYS.include?(key_sym)
          $stderr.puts "[rails-ai-context] WARNING: #{path}: `#{key}` can only be set in the initializer, " \
                       "not in YAML. Ignored."
          next
        end
        unless YAML_KEYS.include?(key_sym)
          # Without this line a dropped key reads exactly like an applied one.
          nearest = nearest_yaml_key(key_sym)
          hint = nearest ? " (did you mean `#{nearest}`?)" : ""
          $stderr.puts "[rails-ai-context] WARNING: #{path}: unknown key `#{key}`#{hint}. Ignored."
          next
        end
        next if value.nil?

        union = UNION_KEYS.include?(key_sym)
        next if config.block_assigned_keys.include?(key_sym) && !union

        begin
          next config.public_send(:"#{key_sym}=", coerce_value(key_sym, value)) unless union

          # A block before the file that assigned the key keeps all it wrote; an in-place edit, what it added.
          current = Array(config.public_send(key_sym)).map(&:to_s)
          current -= defaults.public_send(key_sym) unless config.block_assigned_keys.include?(key_sym)
          config.public_send(:"#{key_sym}=", coerce_value(key_sym, value))
          entries = config.public_send(key_sym).map(&:to_s)
          config.public_send(:"#{key_sym}=", entries | current)
          config.yaml_entries[key_sym] = entries
        rescue ArgumentError => e
          # A bad value degrades the same way bad syntax does: warn, keep the
          # default, and let the rest of the file apply.
          $stderr.puts "[rails-ai-context] WARNING: #{path}: #{key}: #{e.message}. Keeping the default."
        end
      end

      config
    end

    # Load .rails-ai-context.yml as the base over the defaults, once per
    # configuration. A second call is a no-op, so an initializer that edits a
    # key in place keeps the edit; a block that runs before the load keeps the
    # keys it assigns.
    def self.load_config_file!(dir = nil)
      config = RailsAiContext.configuration
      return if config.config_file_applied?

      dir ||= defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : Dir.pwd
      yaml_path = File.join(dir, CONFIG_FILENAME)
      # An absent file is applied too: the file is read at boot, not whenever
      # one appears mid-process.
      config.config_file_applied!
      return unless File.exist?(yaml_path)

      $stderr.puts "[rails-ai-context] Loading configuration from #{CONFIG_FILENAME}" if ENV["DEBUG"]
      load_from_yaml(yaml_path)
    end

    # The entry points that reach the config after the app's initializers have
    # run - the standalone binary and the CLI's boot path. On a booted
    # in-Gemfile app the engine already applied the file, so this is a no-op.
    def self.auto_load!(dir = nil)
      load_config_file!(dir)
    end

    # Only an obvious near miss - a singular/plural slip, or a truncation that
    # still covers half the key. A short prefix like `max` matches several
    # unrelated keys, so it earns no guess.
    def self.nearest_yaml_key(key)
      name = key.to_s.downcase
      return nil if name.length < 3

      YAML_KEYS.find { |k| k.to_s == "#{name}s" || "#{k}s" == name } ||
        YAML_KEYS.find { |k| k.to_s.start_with?(name) && name.length * 2 >= k.to_s.length }
    end
    private_class_method :nearest_yaml_key

    def self.coerce_value(key, value)
      # Any other shape goes to the setter as given, which names the values it takes.
      if SYMBOL_KEYS.include?(key) then value.is_a?(String) ? value.to_sym : value
      elsif SYMBOL_ARRAY_KEYS.include?(key) then names(value, key).map(&:to_sym)
      elsif LIST_KEYS.include?(key) then names(value, key)
      else
        value
      end
    end

    # A list of names, from YAML or Ruby. An empty item, such as an unset ENV
    # lookup, is dropped; a nested list is the same mistake as a bad value.
    def self.names(value, key)
      list = Array(value).compact
      raise ArgumentError, "#{key} must be a list of names (got #{shown(value)})" unless list.all? { |name| name.is_a?(String) || name.is_a?(Symbol) }

      list
    end

    # A number, or text that reads as one (`1e5` included), from YAML or Ruby, cut to a whole number
    # as it always was; a list, a mapping or `300s` is the same mistake as a bad number.
    def self.integer(value, key)
      number = number(value)
      raise ArgumentError, "#{key} must be a number (got #{shown(value)})" unless number.is_a?(Numeric) && number.finite?

      number.to_i
    end

    # Text read as a number, with a leading zero read as decimal: "010" is ten.
    def self.number(value)
      value.is_a?(String) ? Integer(value, 10, exception: false) || Float(value, exception: false) : value
    end

    # A rejected value as an error message names it. With YAML aliases a short file can hold a list
    # too large to print, so a list or mapping goes by its size and a scalar is cut short.
    def self.shown(value)
      case value
      when Array then "a list of #{value.size} item#{'s' unless value.size == 1}"
      when Hash then "a mapping of #{value.size} key#{'s' unless value.size == 1}"
      else
        text = value.inspect
        text.length > 60 ? "#{text[0, 57]}..." : text
      end
    end

    # Keys a `RailsAiContext.configure` block assigned, or any code before the file loaded. The YAML load
    # skips them, so the code wins key by key whether it sits in an initializer,
    # config/application.rb or an environment file.
    def block_assigned_keys
      @block_assigned_keys ||= []
    end

    def config_file_applied?
      @config_file_applied || false
    end

    def config_file_applied!
      @config_file_applied = true
    end

    # Saved and restored, not cleared: a nested configure block must not
    # disarm the outer one for the assignments that follow it.
    def recording_block_assignments
      was_recording = @recording_block_assignments
      @recording_block_assignments = true
      yield self
    ensure
      @recording_block_assignments = was_recording
    end

    # The writer is what records, so assigning a key its default value still
    # claims it for the block; comparing values around the block would not.
    # A union key assigned after the file loaded keeps the file's entries beside the new value.
    BLOCK_ASSIGNMENT_RECORDER = Module.new do
      YAML_KEYS.each do |key|
        define_method(:"#{key}=") do |value|
          super(value)
          block_assigned_keys << key if @recording_block_assignments || !config_file_applied?
          return unless UNION_KEYS.include?(key) && yaml_entries.key?(key)

          instance_variable_set(:"@#{key}", Array(public_send(key)) | yaml_entries[key])
        end
      end
    end

    # What .rails-ai-context.yml gave each union key, so a later assignment keeps it.
    def yaml_entries
      @yaml_entries ||= {}
    end
    prepend BLOCK_ASSIGNMENT_RECORDER

    PRESETS = {
      standard: %i[schema models routes jobs gems conventions controllers tests migrations stimulus
                   view_templates config components
                   turbo auth performance i18n].freeze,
      full: %i[schema models routes jobs gems conventions stimulus database_stats controllers views view_templates turbo
               i18n config active_storage action_text auth api tests rake_tasks assets
               devops action_mailbox migrations seeds middleware engines env_config multi_database
               components performance frontend_frameworks
               initializers autoload connection_pool active_support credentials security observability env].freeze
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

    # Whether the endpoint inside the app (the mounted engine and auto_mount)
    # answers in production, where it would answer every tool to whoever can
    # reach the app. Off, it refuses there with a 403 (default: false).
    attr_accessor :allow_http_in_production

    # HTTP transport settings. http_port's writer validates, below.
    attr_accessor :http_path, :http_bind
    attr_reader :http_port

    # Output directory for generated context files
    attr_accessor :output_dir

    # Filesystem root of the app under analysis. Set by the CLI (--app-path
    # or the working directory) for the static tier; nil means "ask Rails".
    # Deliberately not a YAML key: the config file lives inside the app it
    # would point at.
    attr_accessor :app_root

    # Models/tables to exclude from introspection
    attr_accessor :excluded_models

    # TTL in seconds for cached introspection (default: 60)
    attr_reader :cache_ttl

    # Context file generation mode
    # :compact - ≤150 lines CLAUDE.md, references MCP tools for details (default)
    # :full    - current behavior, dumps everything into context files
    attr_reader :context_mode

    # Max non-blank lines per compact context file (only applies in :compact mode)
    attr_reader :claude_max_lines

    # Max characters for any single MCP tool response (safety net)
    attr_reader :max_tool_response_chars

    # Live reload: auto-invalidate MCP tool caches on file changes
    # :auto (default) - enable if `listen` gem is available, say so on stderr otherwise
    # true  - enable, raise if `listen` gem is missing
    # false - disable entirely
    attr_reader :live_reload

    # Debounce interval in seconds for live reload file watching
    attr_reader :live_reload_debounce

    # Whether to include raw tool arguments in ActiveSupport::Notifications
    # instrumentation events. Default: false (v5.8.1+). When false, only
    # metadata (method, tool_name, duration, error) is forwarded to
    # subscribers. When true, `tool_arguments` and `arguments` are forwarded
    # verbatim - including raw SQL from `rails_query`, env var names from
    # `rails_get_config(section: "env")`, and log search patterns from `rails_read_logs`.
    #
    # Setting this to true means the operator takes on the redaction
    # obligation for any downstream observability pipeline (Datadog, Scout,
    # custom loggers) that receives these events. See CHANGELOG.md for v5.8.1
    # for the security review that changed the default.
    attr_accessor :instrumentation_include_arguments

    # Whether this gem writes context files at all. False is MCP-only: the
    # server and the CLI still answer, and no CLAUDE.md, AGENTS.md, rules
    # file or .ai-context.json is written or touched. Narrower than
    # `generate_root_files`, which still writes the split rule files.
    attr_accessor :context_files

    # Whether to generate root-level context files (CLAUDE.md, AGENTS.md,
    # copilot-instructions.md). When false, only split rule files and .ai-context.json are written.
    attr_accessor :generate_root_files

    # Whether to embed the Anti-Hallucination Protocol section in generated context files.
    # Default: true. Set false to skip the 6-rule verification protocol in CLAUDE.md,
    # AGENTS.md, .claude/rules/, .cursor/rules/, .github/instructions/.
    attr_accessor :anti_hallucination_rules

    # Whether every tool answer ends with one line asking the agent to offer the
    # user a GitHub issue when rails-ai-context answered wrong, missed something
    # or failed. Default: true. About 40 tokens an answer; set false to leave it out.
    attr_accessor :report_issue_line

    # File size limits (bytes) - increase for larger projects
    attr_reader :max_file_size            # Per-file read limit for tools (default: 5MB)
    attr_reader :max_test_file_size       # Test file read limit (default: 1MB)
    attr_reader :max_schema_file_size     # schema.rb / structure.sql parse limit (default: 10MB)
    # Doctor thresholds, not read caps: the view tools do not stop at them.
    attr_reader :max_view_total_size      # Size of app/views doctor warns past (default: 10MB)
    attr_reader :max_view_file_size       # Accepted and stored; no check reads it (default: 1MB)
    attr_reader :max_search_results       # Max lines a search may emit, matches and context together (default: 200)
    attr_reader :max_validate_files       # Max files per validate call (default: 50)

    # Additional MCP tool classes to register alongside built-in tools
    attr_accessor :custom_tools

    # Built-in tool names to skip (e.g. %w[rails_security_scan rails_query]).
    # Written through a coercing setter - see #skip_tools=.
    attr_reader :skip_tools

    # Which AI tools to generate context for (selected during install)
    # nil = all formats, or %i[claude cursor copilot opencode codex]
    attr_writer :ai_tools

    # The configure block sets it; an app that recorded its selection without
    # one - zero-config, or an initializer whose line is still commented out -
    # answers from the record, so no surface re-asks a question already
    # answered.
    def ai_tools
      return @ai_tools unless @ai_tools.nil?

      # Read once per root, so each call does not read every initializer again.
      root = selection_root
      return @ai_tools_read if @ai_tools_read_root == root

      @ai_tools_read_root = root
      @ai_tools_read = UnbootedSettings.read(root).ai_tools
    end

    # Tool invocation mode: :mcp (MCP primary + CLI fallback) or :cli (CLI only)
    attr_reader :tool_mode

    def selection_root
      app_root || (defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : Dir.pwd)
    end
    private :selection_root

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

    # Each pattern ends on a whole namespace segment: an app's own
    # ActiveRecordLikeInterface is not ActiveRecord's.
    DEFAULT_EXCLUDED_CONCERNS = [
      /::Generated(Association|Attribute|Relation)Methods\z/,
      /\A(ActiveRecord|ActiveModel|ActiveSupport|ActionText|ActionMailbox|ActiveStorage)(::|\z)/,
      /\A(ActionDispatch|ActionController|ActionView|AbstractController)(::|\z)/,
      /\A(Devise::Models|Devise::Orm|Bullet|Turbo|GlobalID|Rolify)(::|\z)/,
      # The `debug` gem (default in Rails 7.0+ Gemfiles) prepends this onto
      # Kernel, so it shows up in every model's ancestors - not a real concern.
      /\ADEBUGGER__::/
    ].freeze

    DEFAULT_EXCLUDED_ASSOCIATION_NAMES = %w[
      active_storage_attachments active_storage_blobs
      rich_text_body rich_text_content
      action_mailbox_inbound_emails
      noticed_events noticed_notifications
    ].freeze

    # Filtering - customize what's hidden from AI output
    attr_accessor :excluded_controllers   # Controller classes hidden from listings (e.g. DeviseController)
    attr_accessor :excluded_route_prefixes # Route controller prefixes hidden with app_only (e.g. action_mailbox/)
    # Regex patterns for concerns to hide (e.g. /Devise::Models/).
    # Written through a coercing setter - see #excluded_concerns=.
    attr_reader :excluded_concerns
    attr_accessor :excluded_filters       # Framework filter names hidden from controller output
    attr_accessor :excluded_middleware     # Default middleware hidden from config output
    attr_accessor :excluded_association_names # Framework association names hidden from model output

    # Search and file discovery
    attr_accessor :search_extensions      # Narrow the Ruby fallback to these extensions; nil (default) searches every file, as ripgrep does
    attr_accessor :concern_paths          # Where to look for concern source files (default: nil, discovers app/*/concerns)

    # Frontend framework detection (optional overrides - auto-detected if nil)
    attr_accessor :frontend_paths         # User-declared frontend dirs (e.g. ["app/frontend", "../web-client"]; one outside the app root is read for manifests only)

    # Additional app-root-relative directories that also contain Rails app
    # code (e.g. ["src", "vendor/internal"]). Code discovery scans each
    # entry's app/models, app/controllers, and app/views subdirectories.
    attr_accessor :extra_app_paths

    # Database query tool settings (rails_query)
    attr_reader :query_timeout                # Statement timeout in seconds, a positive number (default: 5)
    attr_reader :query_row_limit              # Max rows returned (default: 100, hard cap: 1000)
    attr_accessor :query_redacted_columns     # Column names a query may not reference, redacted in output
    attr_accessor :query_allowed_columns      # Column names to exempt from the built-in sensitive list
    attr_accessor :allow_query_in_production  # Allow rails_query in production (default: false)

    # Log reading settings (rails_read_logs)
    attr_reader :log_lines                    # Default lines to tail (default: 50)

    # Hydration: inject schema hints into controller/view tool responses
    attr_accessor :hydration_enabled          # Enable/disable hydration (default: true)
    attr_reader :hydration_max_hints          # Max schema hints per response (default: 5)

    def initialize
      @server_name         = "rails-ai-context"
      @introspectors       = PRESETS[:full].dup
      @excluded_paths      = %w[node_modules tmp log vendor .git doc docs]
      # Files each tool's own docs say to gitignore. A placeholder beside one
      # (config/application.example.yml, .env.example) stays readable: see SafePath.sensitive?.
      @sensitive_patterns  = %w[
        .env .env.* *.env .envrc
        config/master.key
        config/credentials.yml.enc config/credentials/*.yml.enc
        config/database.yml config/secrets*.yml config/secrets*.yml.enc
        config/application.yml
        config/settings.local.yml config/settings/*.local.yml
        config/cable.yml config/storage.yml
        config/mongoid.yml config/redis.yml
        *.pem *.key *.p8 *.p12 *.pfx *.jks *.keystore
        **/id_rsa **/id_ed25519 **/id_ecdsa **/id_dsa
        .ssh/* .aws/credentials .aws/config .netrc .pgpass .my.cnf
        .npmrc .yarnrc .bundle/config
      ]
      @auto_mount          = false
      @allow_http_in_production = false
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
      @instrumentation_include_arguments = false
      @context_files            = true
      @generate_root_files      = true
      @anti_hallucination_rules = true
      @report_issue_line        = true
      @max_file_size            = 5_000_000
      @max_test_file_size       = 1_000_000
      @max_schema_file_size     = 10_000_000
      @max_view_total_size      = 10_000_000
      @max_view_file_size       = 1_000_000
      @max_search_results       = 200
      @max_validate_files       = 50
      @excluded_controllers     = %w[DeviseController Devise::OmniauthCallbacksController]
      # The routes Rails' engines and gems draw on their own. A route the app's
      # own files declare is the app's, framework controller or not: `devise_for`
      # and the `get "up" => "rails/health#show"` every new app writes.
      @excluded_route_prefixes  = %w[action_mailbox/ active_storage/ rails/conductor/ rails/info rails/mailers rails/welcome turbo/]
      @excluded_concerns        = DEFAULT_EXCLUDED_CONCERNS.dup
      @excluded_filters         = DEFAULT_EXCLUDED_FILTERS.dup
      @excluded_middleware      = DEFAULT_EXCLUDED_MIDDLEWARE.dup
      @excluded_association_names = DEFAULT_EXCLUDED_ASSOCIATION_NAMES.dup
      @custom_tools             = []
      @skip_tools               = []
      @ai_tools                 = nil
      @tool_mode                = :mcp
      @search_extensions        = nil
      @concern_paths            = nil
      @frontend_paths           = nil
      @extra_app_paths          = []
      @query_timeout            = 5
      @query_row_limit          = 100
      @query_redacted_columns   = SecretColumns::DEFAULT_REDACTED_COLUMNS.dup
      @query_allowed_columns    = []
      @allow_query_in_production = false
      @log_lines                = 50
      @hydration_enabled        = true
      @hydration_max_hints      = 5
    end

    def preset=(name)
      raise ArgumentError, "preset must be #{PRESETS.keys.join(' or ')} (got #{self.class.shown(name)})" unless name.respond_to?(:to_sym)

      name = name.to_sym
      raise ArgumentError, "Unknown preset: #{self.class.shown(name.to_s)}. Valid presets: #{PRESETS.keys.join(", ")}" unless PRESETS.key?(name)
      self.introspectors = PRESETS[name].dup
    end

    # A tool name is a String, and both the MCP server and the CLI compare
    # against one. Every neighbouring key in the generated initializer takes
    # symbols, so %i[] is written often enough that accepting it as a no-op
    # meant a configured skip silently kept the tool.
    def skip_tools=(value)
      @skip_tools = self.class.names(value, :skip_tools).map(&:to_s)
    end

    # A YAML file can only carry strings, and an invalid one would otherwise
    # raise RegexpError inside an introspector, far from the file that named
    # it. Compile at load, and report a bad pattern the way a bad value is.
    def excluded_concerns=(value)
      @excluded_concerns = Array(value).map do |pattern|
        next pattern if pattern.is_a?(Regexp)

        begin
          Regexp.new(pattern.to_s)
        rescue RegexpError => e
          raise ArgumentError, "invalid pattern #{self.class.shown(pattern.to_s)} (#{e.message})"
        end
      end
    end

    def output_dir_for(app)
      @output_dir || app.root.to_s
    end

    def http_port=(value)
      value = self.class.integer(value, :http_port)
      raise ArgumentError, "http_port must be between 1 and 65535 (got #{self.class.shown(value)})" unless value.between?(1, 65535)
      @http_port = value
    end

    def cache_ttl=(value)
      value = self.class.integer(value, :cache_ttl)
      raise ArgumentError, "cache_ttl must be positive (got #{self.class.shown(value)})" unless value > 0
      @cache_ttl = value
    end

    def claude_max_lines=(value)
      value = self.class.integer(value, :claude_max_lines)
      raise ArgumentError, "claude_max_lines must be positive (got #{self.class.shown(value)})" unless value > 0
      @claude_max_lines = value
    end

    def max_tool_response_chars=(value)
      value = self.class.integer(value, :max_tool_response_chars)
      raise ArgumentError, "max_tool_response_chars must be positive (got #{self.class.shown(value)})" unless value > 0
      @max_tool_response_chars = value
    end

    # A fraction of a second is kept as given: each database family rounds it up to the least it can bound.
    def query_timeout=(value)
      number = self.class.number(value)
      unless number.is_a?(Numeric) && number.real? && number.positive? && number.finite?
        raise ArgumentError, "query_timeout must be positive (got #{self.class.shown(value)})"
      end

      @query_timeout = number
    end

    def query_row_limit=(value)
      value = self.class.integer(value, :query_row_limit)
      raise ArgumentError, "query_row_limit must be between 1 and 1000 (got #{self.class.shown(value)})" unless value.between?(1, 1000)
      @query_row_limit = value
    end

    # Every reader asks for :full or :cli by name, so any other value was
    # kept and read as the default: a typo gave compact files, or MCP-mode
    # files, with nothing said.
    def context_mode=(value)
      @context_mode = one_of(:context_mode, value, CONTEXT_MODES)
    end

    def tool_mode=(value)
      @tool_mode = one_of(:tool_mode, value, TOOL_MODES)
    end

    # The server reads only false as off, so any other value would turn live reload on silently.
    def live_reload=(value)
      @live_reload =
        case value
        when true, "true" then true
        when false, "false" then false
        when :auto, "auto" then :auto
        else raise ArgumentError, "live_reload must be true, false or auto (got #{self.class.shown(value)})"
        end
    end

    def live_reload_debounce=(value)
      number = value.is_a?(String) ? Float(value, exception: false) : value
      unless number.is_a?(Numeric) && number.real? && number.finite? && !number.negative?
        raise ArgumentError, "live_reload_debounce must be a number of seconds (got #{self.class.shown(value)})"
      end

      @live_reload_debounce = number
    end

    def one_of(key, value, allowed)
      symbol = value.respond_to?(:to_sym) ? value.to_sym : value
      return symbol if allowed.include?(symbol)

      raise ArgumentError, "#{key} must be #{allowed.join(' or ')} (got #{self.class.shown(value)})"
    end
    private :one_of

    # Zero hints turns hydration off; every other key caps a size or a count, where zero lets nothing through.
    INTEGER_KEYS.each do |key|
      next if instance_methods(false).include?(:"#{key}=")

      least = key == :hydration_max_hints ? 0 : 1
      define_method(:"#{key}=") do |value|
        value = self.class.integer(value, key)
        raise ArgumentError, "#{key} must be #{least.zero? ? 'zero or more' : 'positive'} (got #{self.class.shown(value)})" if value < least

        instance_variable_set(:"@#{key}", value)
      end
    end
  end
end
