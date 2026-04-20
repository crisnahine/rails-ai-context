# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Reports which Rails-related environment variables are currently set
    # in the running process. Values are NEVER returned for sensitive vars
    # (SECRET_KEY_BASE, DATABASE_URL, REDIS_URL, etc.) — only presence
    # (boolean). Safe, non-sensitive vars report their value.
    # Covers RAILS_NERVOUS_SYSTEM.md §36 (ENV vars Rails reads).
    class EnvIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        {
          set: envs_that_are_set,
          unset: envs_that_are_unset,
          referenced_in_code: scan_env_references
        }
      rescue => e
        $stderr.puts "[rails-ai-context] EnvIntrospector#call failed: #{e.message}" if ENV["DEBUG"]
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      # Rails / Bundler / web-server environment variables the framework
      # documents or checks. `safe: true` = value is returned verbatim when
      # set; `safe: false` = only presence reported (never the value).
      KNOWN_ENV_VARS = [
        # Core Rails
        { name: "RAILS_ENV",                    safe: true,  category: :core,       doc: "Rails environment (development, test, production)." },
        { name: "RACK_ENV",                     safe: true,  category: :core,       doc: "Rack environment (falls back to RAILS_ENV)." },
        { name: "RAILS_RELATIVE_URL_ROOT",      safe: true,  category: :core,       doc: "Mount Rails at a sub-path." },
        { name: "RAILS_LOG_LEVEL",              safe: true,  category: :logging,    doc: "Logger level (debug/info/warn/error/fatal)." },
        { name: "RAILS_LOG_TO_STDOUT",          safe: true,  category: :logging,    doc: "When set, logs go to stdout instead of log/*.log." },
        { name: "RAILS_MAX_THREADS",            safe: true,  category: :server,     doc: "Puma thread count & ActiveRecord pool default." },
        { name: "RAILS_MIN_THREADS",            safe: true,  category: :server,     doc: "Puma minimum threads." },
        { name: "WEB_CONCURRENCY",              safe: true,  category: :server,     doc: "Puma worker (process) count." },
        { name: "PORT",                         safe: true,  category: :server,     doc: "HTTP port (Puma, Thruster)." },
        { name: "HOST",                         safe: true,  category: :server,     doc: "Bind address (Puma, Thruster)." },

        # Assets / eager load
        { name: "RAILS_SERVE_STATIC_FILES",     safe: true,  category: :assets,     doc: "Serve static assets from Rails (vs an edge CDN/nginx)." },
        { name: "RAILS_EAGER_LOAD",             safe: true,  category: :boot,       doc: "Force eager_load regardless of environment." },

        # Master key / credentials — presence only
        { name: "RAILS_MASTER_KEY",             safe: false, category: :secrets,    doc: "Master key for config/credentials.yml.enc." },
        { name: "SECRET_KEY_BASE",              safe: false, category: :secrets,    doc: "Session / signed cookie / MessageEncryptor key." },

        # Database — presence only
        { name: "DATABASE_URL",                 safe: false, category: :database,   doc: "Primary database connection URL." },
        { name: "PRIMARY_DATABASE_URL",         safe: false, category: :database,   doc: "Explicit primary DB URL (multi-db setups)." },
        { name: "CACHE_DATABASE_URL",           safe: false, category: :database,   doc: "Solid Cache / cache DB URL." },
        { name: "QUEUE_DATABASE_URL",           safe: false, category: :database,   doc: "Solid Queue DB URL." },
        { name: "CABLE_DATABASE_URL",           safe: false, category: :database,   doc: "Solid Cable DB URL." },

        # Cache / jobs / Redis
        { name: "REDIS_URL",                    safe: false, category: :cache,      doc: "Redis URL (cache / Sidekiq / Action Cable)." },
        { name: "REDIS_CACHE_URL",              safe: false, category: :cache,      doc: "Dedicated Redis URL for caching." },
        { name: "MEMCACHED_URL",                safe: false, category: :cache,      doc: "Memcached URL." },

        # Kamal / deployment
        { name: "KAMAL_REGISTRY_PASSWORD",      safe: false, category: :deploy,     doc: "Kamal container registry password." },
        { name: "KAMAL_HOST",                   safe: true,  category: :deploy,     doc: "Kamal target host override." },

        # Heroku
        { name: "DYNO",                         safe: true,  category: :platform,   doc: "Heroku dyno name." },
        { name: "HEROKU_APP_NAME",              safe: true,  category: :platform,   doc: "Heroku app name." },

        # Bundler / gem loading — paths are absolute and contain the OS
        # username on most systems (e.g. /Users/alice/.bundle), so we redact
        # their values and report only presence.
        { name: "BUNDLE_GEMFILE",               safe: false, category: :bundler,    doc: "Path to the Gemfile Bundler uses." },
        { name: "BUNDLE_PATH",                  safe: false, category: :bundler,    doc: "Path where gems are installed." },
        { name: "DISABLE_SPRING",               safe: true,  category: :bundler,    doc: "Disable Spring preloader." },

        # Rails 8.1
        { name: "RAILS_EVENT_REPORTER",         safe: true,  category: :observability, doc: "Enable structured event reporter (8.1+)." },

        # Testing / parallelism
        { name: "PARALLEL_WORKERS",             safe: true,  category: :testing,    doc: "Parallel test worker count." },
        { name: "TEST_ENV_NUMBER",              safe: true,  category: :testing,    doc: "Worker-specific identifier for parallel tests." },
        { name: "CI",                           safe: true,  category: :testing,    doc: "Set by most CI systems." }
      ].freeze

      def envs_that_are_set
        KNOWN_ENV_VARS.filter_map do |spec|
          next unless ENV.key?(spec[:name]) && !ENV[spec[:name]].to_s.empty?

          entry = {
            name: spec[:name],
            category: spec[:category].to_s,
            doc: spec[:doc]
          }
          entry[:value] = ENV[spec[:name]] if spec[:safe]
          entry[:redacted] = true unless spec[:safe]
          entry
        end
      end

      def envs_that_are_unset
        KNOWN_ENV_VARS.filter_map do |spec|
          next if ENV.key?(spec[:name]) && !ENV[spec[:name]].to_s.empty?
          { name: spec[:name], category: spec[:category].to_s }
        end
      end

      # Scan config/ and app/ for `ENV["FOO"]` / `ENV.fetch("FOO")` references
      # to surface custom env vars the app reads beyond the known catalog.
      def scan_env_references
        refs = {}
        %w[config app lib].each do |rel|
          dir = File.join(root, rel)
          next unless Dir.exist?(dir)

          # Sort before slicing — see rationale in active_support_introspector.
          Dir.glob(File.join(dir, "**/*.rb")).sort.first(2000).each do |path|
            content = RailsAiContext::SafeFile.read(path) or next
            content.scan(/\bENV\s*(?:\.fetch)?\s*[\[\(]\s*["']([A-Z][A-Z0-9_]{1,})["']/).flatten.each do |name|
              next if KNOWN_ENV_VARS.any? { |spec| spec[:name] == name }
              refs[name] ||= []
              refs[name] << path.sub("#{root}/", "") unless refs[name].size >= 3
            end
          end
        end
        refs.map { |name, files| { name: name, files: files, set: ENV.key?(name) && !ENV[name].to_s.empty? } }.sort_by { |h| h[:name] }
      rescue => e
        $stderr.puts "[rails-ai-context] scan_env_references failed: #{e.message}" if ENV["DEBUG"]
        []
      end
    end
  end
end
