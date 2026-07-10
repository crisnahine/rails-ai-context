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
        arch << "concerns_models" if concern_files_exist?("app/models/concerns")
        arch << "concerns_controllers" if concern_files_exist?("app/controllers/concerns")
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

          # Collect AST-detected macros across all model files
          all_macros = Set.new
          all_association_options = []

          model_files.first(500).each do |path|
            ast = SourceIntrospector.walk(path, {
              macros: -> {
                Listeners::GenericMacroListener.new(
                  :acts_as_paranoid, :discard, :has_paper_trail, :audited,
                  :aasm, :state_machine, :workflow,
                  :acts_as_tenant, :apartment,
                  :searchkick, :pg_search, :ransack,
                  :acts_as_taggable, :acts_as_taggable_on,
                  :friendly_id, :sluggable,
                  :acts_as_nested_set, :ancestry, :closure_tree
                )
              },
              builtin_macros: Listeners::MacrosListener,
              associations: Listeners::AssociationsListener
            })

            ast[:macros].each { |h| all_macros << h[:macro] }
            ast[:builtin_macros].each { |h| all_macros << h[:macro] }
            ast[:associations].each { |a| all_association_options << a[:options] }
          end

          # STI detection via AST: extract parent class from ClassNode, check schema
          app_model_names = model_files.filter_map { |f| File.basename(f, ".rb").camelize }
          schema_path = File.join(root, "db/schema.rb")
          schema_content = File.exist?(schema_path) ? (RailsAiContext::SafeFile.read(schema_path) || "") : ""

          has_sti_subclass = false
          has_inheritance_column = false
          has_current_attributes = false
          has_deleted_at = false

          model_files.first(500).each do |f|
            parent = extract_parent_class(f)
            if parent && app_model_names.include?(parent) && parent != "ApplicationRecord"
              parent_table = parent.underscore.pluralize
              if schema_content.match?(/create_table\s+"#{Regexp.escape(parent_table)}".*?t\.\w+\s+"type"/m)
                has_sti_subclass = true
              end
            end

            superclass = extract_superclass_path(f)
            has_current_attributes = true if superclass == "ActiveSupport::CurrentAttributes"

            # self.inheritance_column= is an assignment via CallNode with self receiver
            inheritance_check = SourceIntrospector.walk(f, {
              inh: -> { Listeners::ChainedCallListener.new(:inheritance_column=) }
            })
            has_inheritance_column = true if inheritance_check[:inh].any?

            # deleted_at is a keyword/content check, not structural -- keep regex
            unless has_deleted_at
              src = RailsAiContext::SafeFile.read(f)
              has_deleted_at = true if src&.match?(/deleted_at/)
            end
          end

          patterns << "sti" if has_inheritance_column || has_sti_subclass

          patterns << "polymorphic" if all_association_options.any? { |opts| opts[:polymorphic] == true }
          patterns << "soft_delete" if all_macros.intersect?(%i[acts_as_paranoid discard].to_set) || has_deleted_at
          patterns << "versioning" if all_macros.intersect?(%i[has_paper_trail audited].to_set)
          patterns << "state_machine" if all_macros.intersect?(%i[aasm state_machine workflow].to_set)
          patterns << "multi_tenancy" if all_macros.intersect?(%i[acts_as_tenant apartment].to_set)
          patterns << "searchable" if all_macros.intersect?(%i[searchkick pg_search ransack].to_set)
          patterns << "taggable" if all_macros.intersect?(%i[acts_as_taggable acts_as_taggable_on].to_set)
          patterns << "sluggable" if all_macros.intersect?(%i[friendly_id sluggable].to_set)
          patterns << "nested_set" if all_macros.intersect?(%i[acts_as_nested_set ancestry closure_tree].to_set)
          patterns << "current_attributes" if has_current_attributes
          patterns << "encrypted_attributes" if all_macros.include?(:encrypts)
          patterns << "normalizations" if all_macros.include?(:normalizes)
        end

        patterns << "view_components" if dir_exists?("app/components")
        patterns << "phlex" if gem_present?("phlex-rails")
        patterns << "async_queries" if uses_async_queries?

        patterns
      end

      ASYNC_QUERY_METHODS = %i[
        load_async
        async_count async_sum async_minimum async_maximum async_average
        async_pluck async_ids async_exists async_find_by async_find
        async_first async_last async_take
      ].freeze

      def uses_async_queries?
        %w[app/controllers app/services app/jobs app/models].any? do |rel_dir|
          dir = File.join(root, rel_dir)
          next false unless Dir.exist?(dir)

          Dir.glob(File.join(dir, "**/*.rb")).first(500).any? do |f|
            # AST-based detection: ignores comments automatically
            ast = SourceIntrospector.walk(f, {
              async: -> { Listeners::ChainedCallListener.new(*ASYNC_QUERY_METHODS) }
            })
            ast[:async].any?
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

      # Extract the parent class name from a Ruby file via AST ClassNode.
      # Returns a simple name like "User" (no module path).
      def extract_parent_class(path)
        parse_result = AstCache.parse(path)
        find_parent_class(parse_result.value)
      rescue => e
        $stderr.puts "[rails-ai-context] extract_parent_class failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # Extract the full superclass path (e.g. "ActiveSupport::CurrentAttributes").
      def extract_superclass_path(path)
        parse_result = AstCache.parse(path)
        find_superclass_path(parse_result.value)
      rescue => e
        $stderr.puts "[rails-ai-context] extract_superclass_path failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def find_parent_class(node)
        case node
        when Prism::ProgramNode
          find_parent_class(node.statements)
        when Prism::StatementsNode
          node.body.each do |child|
            result = find_parent_class(child)
            return result if result
          end
          nil
        when Prism::ClassNode
          superclass = node.superclass
          case superclass
          when Prism::ConstantReadNode then superclass.name.to_s
          when Prism::ConstantPathNode
            # Return just the final name for simple parent matching
            superclass.name.to_s
          else nil
          end
        when Prism::ModuleNode
          node.body&.body&.each do |child|
            result = find_parent_class(child)
            return result if result
          end
          nil
        else nil
        end
      end

      def find_superclass_path(node)
        case node
        when Prism::ProgramNode
          find_superclass_path(node.statements)
        when Prism::StatementsNode
          node.body.each do |child|
            result = find_superclass_path(child)
            return result if result
          end
          nil
        when Prism::ClassNode
          superclass = node.superclass
          case superclass
          when Prism::ConstantReadNode then superclass.name.to_s
          when Prism::ConstantPathNode then constant_path_to_string(superclass)
          else nil
          end
        when Prism::ModuleNode
          node.body&.body&.each do |child|
            result = find_superclass_path(child)
            return result if result
          end
          nil
        else nil
        end
      end

      def constant_path_to_string(node)
        parts = []
        current = node
        while current.is_a?(Prism::ConstantPathNode)
          parts.unshift(current.name.to_s)
          current = current.parent
        end
        parts.unshift(current.name.to_s) if current.is_a?(Prism::ConstantReadNode)
        parts.join("::")
      end

      def dir_exists?(relative_path)
        Dir.exist?(File.join(root, relative_path))
      end

      # A freshly-generated Rails app ships empty concerns/ directories (holding
      # only a .keep file), so directory existence alone isn't evidence the
      # pattern is in use. Require at least one real Ruby file inside.
      def concern_files_exist?(relative_path)
        Dir.glob(File.join(root, relative_path, "**", "*.rb")).any?
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
