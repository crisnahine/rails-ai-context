# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Detects high-level Rails conventions and patterns in use,
    # giving AI assistants critical context about the app's architecture.
    class ConventionIntrospector
      attr_reader :app

      def initialize(app)
        @app = app
      end

      # @return [Hash] detected conventions and patterns
      def call
        {
          architecture: detect_architecture,
          patterns: detect_patterns,
          directory_structure: scan_directory_structure,
          config_files: detect_config_files,
          custom_directories: detect_custom_directories
        }
      end

      private

      def root
        app.root.to_s
      end

      def detect_architecture
        arch = []
        arch << "api_only" if app.config.api_only
        arch << "hotwire" if dir_exists?("app/javascript/controllers") || gem_present?("turbo-rails")
        arch << "graphql" if dir_exists?("app/graphql")
        arch << "grape_api" if dir_exists?("app/api")
        arch << "service_objects" if dir_exists?("app/services")
        arch << "form_objects" if dir_exists?("app/forms")
        arch << "query_objects" if dir_exists?("app/queries")
        arch << "presenters" if dir_exists?("app/presenters") || dir_exists?("app/decorators")
        arch << "view_components" if dir_exists?("app/components")
        arch << "phlex" if gem_present?("phlex-rails")
        arch << "stimulus" if dir_exists?("app/javascript/controllers")
        arch << "importmaps" if file_exists?("config/importmap.rb")
        arch << "concerns_models" if dir_exists?("app/models/concerns")
        arch << "concerns_controllers" if dir_exists?("app/controllers/concerns")
        arch << "validators" if dir_exists?("app/validators")
        arch << "policies" if dir_exists?("app/policies")
        arch << "serializers" if dir_exists?("app/serializers")
        arch << "notifiers" if dir_exists?("app/notifiers")
        arch << "pwa" if file_exists?("app/views/pwa")
        arch << "docker" if file_exists?("Dockerfile") || file_exists?("docker-compose.yml")
        arch << "kamal" if file_exists?("config/deploy.yml")
        arch << "ci_github_actions" if dir_exists?(".github/workflows")
        arch << "solid_queue" if gem_present?("solid_queue")
        arch << "solid_cache" if gem_present?("solid_cache")
        arch << "solid_cable" if gem_present?("solid_cable")
        %w[dry-validation dry-types dry-struct dry-monads].each do |gem|
          arch << "dry_rb" if gem_present?(gem)
        end
        arch << "multi_tenant" if gem_present?("apartment") || gem_present?("acts_as_tenant") || gem_present?("ros-apartment")
        arch << "feature_flags" if gem_present?("flipper") || gem_present?("launchdarkly-server-sdk") || gem_present?("split") || gem_present?("unleash")
        arch << "error_monitoring" if gem_present?("sentry-ruby") || gem_present?("bugsnag") || gem_present?("honeybadger") || gem_present?("rollbar") || gem_present?("airbrake")
        arch << "event_driven" if gem_present?("ruby-kafka") || gem_present?("karafka") || gem_present?("bunny") || gem_present?("sneakers") || gem_present?("aws-sdk-sns") || gem_present?("aws-sdk-sqs")
        arch << "zeitwerk" if defined?(Zeitwerk) && defined?(Rails) && Rails.autoloaders.respond_to?(:main)
        arch.uniq
      end

      def detect_patterns
        patterns = []

        # Check for common Rails patterns in model files
        model_dir = File.join(root, "app/models")
        if Dir.exist?(model_dir)
          model_files = Dir.glob(File.join(model_dir, "**/*.rb"))
          content = model_files.first(500).map { |f| RailsAiContext::SafeFile.read(f) || "" }.join("\n")

          # STI: explicit inheritance_column, or a model that inherits from another app model
          # with a `type` column (verified via schema.rb or model source)
          app_model_names = model_files.filter_map { |f| File.basename(f, ".rb").camelize }
          schema_path = File.join(root, "db/schema.rb")
          schema_content = File.exist?(schema_path) ? (RailsAiContext::SafeFile.read(schema_path) || "") : ""
          has_sti_subclass = model_files.any? do |f|
            src = RailsAiContext::SafeFile.read(f) || ""
            parent_match = src.match(/class\s+\w+\s*<\s*(\w+)/)
            next false unless parent_match && app_model_names.include?(parent_match[1]) && parent_match[1] != "ApplicationRecord"
            # Verify parent's table has a `type` column
            parent_table = parent_match[1].underscore.pluralize
            schema_content.match?(/create_table\s+"#{Regexp.escape(parent_table)}".*?t\.\w+\s+"type"/m)
          end
          patterns << "sti" if content.match?(/self\.inheritance_column/) || has_sti_subclass
          patterns << "polymorphic" if content.match?(/polymorphic:\s*true/)
          patterns << "soft_delete" if content.match?(/acts_as_paranoid|discard|deleted_at/)
          patterns << "versioning" if content.match?(/has_paper_trail|audited/)
          patterns << "state_machine" if content.match?(/aasm|state_machine|workflow/)
          patterns << "multi_tenancy" if content.match?(/acts_as_tenant|apartment/)
          patterns << "searchable" if content.match?(/searchkick|pg_search|ransack/)
          patterns << "taggable" if content.match?(/acts_as_taggable/)
          patterns << "sluggable" if content.match?(/friendly_id|sluggable/)
          patterns << "nested_set" if content.match?(/acts_as_nested_set|ancestry|closure_tree/)
          patterns << "current_attributes" if content.match?(/< ActiveSupport::CurrentAttributes/)
          patterns << "encrypted_attributes" if content.match?(/\bencrypts\s+:/)
          patterns << "normalizations" if content.match?(/\bnormalizes\s+:/)
        end

        patterns << "view_components" if dir_exists?("app/components")
        patterns << "phlex" if gem_present?("phlex-rails")
        patterns << "async_queries" if uses_async_queries?

        patterns
      end

      ASYNC_QUERY_PATTERN = /\bload_async\b|\.async_(count|sum|minimum|maximum|average|pluck|ids|exists|find_by|find|first|last|take)\b/

      def uses_async_queries?
        %w[app/controllers app/services app/jobs app/models].any? do |rel_dir|
          dir = File.join(root, rel_dir)
          next false unless Dir.exist?(dir)

          Dir.glob(File.join(dir, "**/*.rb")).first(500).any? do |f|
            content = RailsAiContext::SafeFile.read(f) or next false
            content.match?(ASYNC_QUERY_PATTERN)
          end
        end
      rescue => e
        $stderr.puts "[rails-ai-context] uses_async_queries? failed: #{e.message}" if ENV["DEBUG"]
        false
      end

      def scan_directory_structure
        important_dirs = %w[
          app/models app/controllers app/views app/jobs
          app/mailers app/channels app/services app/forms
          app/queries app/presenters app/decorators
          app/components app/graphql app/api
          app/policies app/serializers app/validators
          app/notifiers app/mailboxes
          app/javascript/controllers
          config/initializers db/migrate lib/tasks
          spec test
        ]

        important_dirs.each_with_object({}) do |dir, hash|
          full_path = File.join(root, dir)
          next unless Dir.exist?(full_path)

          count = Dir.glob(File.join(full_path, "**/*.rb")).size
          count += Dir.glob(File.join(full_path, "**/*.js")).size if dir.include?("javascript")

          hash[dir] = count if count > 0
        end
      end

      def detect_config_files
        configs = %w[
          config/database.yml config/credentials.yml.enc
          config/cable.yml config/storage.yml
          config/sidekiq.yml config/deploy.yml
          config/importmap.rb config/tailwind.config.js
          config/puma.rb config/application.rb
          config/locales/en.yml
          package.json Gemfile
          Procfile Procfile.dev
          .rubocop.yml .rspec
          Dockerfile docker-compose.yml
          .github/workflows/ci.yml
        ]

        configs.select { |f| file_exists?(f) }
      end

      STANDARD_APP_DIRS = %w[
        models controllers views helpers jobs mailers channels components
        assets javascript
      ].to_set.freeze

      def detect_custom_directories
        app_dir = File.join(root, "app")
        return [] unless Dir.exist?(app_dir)

        Dir.children(app_dir)
          .select { |d| File.directory?(File.join(app_dir, d)) }
          .reject { |d| STANDARD_APP_DIRS.include?(d) }
          .sort
      rescue => e
        $stderr.puts "[rails-ai-context] detect_custom_directories failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def dir_exists?(relative_path)
        Dir.exist?(File.join(root, relative_path))
      end

      def file_exists?(relative_path)
        File.exist?(File.join(root, relative_path))
      end

      def gem_present?(name)
        gemfile_lock_content.include?("    #{name} (")
      end

      def gemfile_lock_content
        @gemfile_lock_content ||= begin
          lock_path = File.join(root, "Gemfile.lock")
          File.exist?(lock_path) ? (RailsAiContext::SafeFile.read(lock_path) || "") : ""
        end
      end
    end
  end
end
