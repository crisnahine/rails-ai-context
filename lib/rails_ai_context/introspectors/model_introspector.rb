# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts ActiveRecord model metadata using a hybrid approach:
    # - Rails reflection for runtime data (associations, validations, enums, table info)
    # - Prism AST for source-level declarations (scopes, callbacks, macros, methods)
    #
    # The AST layer replaces all regex/scan/match? source parsing with
    # Prism::Dispatcher-based single-pass extraction via SourceIntrospector.
    class ModelIntrospector
      attr_reader :app, :config

      EXCLUDED_CALLBACKS = %w[autosave_associated_records_for].freeze

      def initialize(app)
        @app    = app
        @config = RailsAiContext.configuration
      end

      # @return [Hash] model metadata keyed by model name
      def call
        eager_load_models!
        models = discover_models

        models.each_with_object({}) do |model, hash|
          hash[model.name] = extract_model_details(model)
        rescue => e
          hash[model.name] = { error: e.message }
        end
      end

      private

      def eager_load_models!
        return if Rails.application.config.eager_load

        models_path = File.join(app.root, "app", "models")
        if defined?(Zeitwerk) && Dir.exist?(models_path) &&
           Rails.autoloaders.respond_to?(:main) && Rails.autoloaders.main.respond_to?(:eager_load_dir)
          Rails.autoloaders.main.eager_load_dir(models_path)
        else
          Rails.application.eager_load!
        end
      rescue => e
        $stderr.puts "[rails-ai-context] eager_load_models! failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def discover_models
        return [] unless defined?(ActiveRecord::Base)

        models = ActiveRecord::Base.descendants.reject do |model|
          model.abstract_class? ||
            model.name.nil? ||
            config.excluded_models.include?(model.name)
        end

        models_dir = File.join(app.root.to_s, "app", "models")
        if Dir.exist?(models_dir)
          known = models.map(&:name).to_set
          Dir.glob(File.join(models_dir, "**", "*.rb")).each do |path|
            relative = path.sub("#{models_dir}/", "").sub(/\.rb\z/, "")
            class_name = relative.camelize
            next if known.include?(class_name)
            next if config.excluded_models.include?(class_name)

            begin
              klass = class_name.constantize
              next unless klass < ActiveRecord::Base && !klass.abstract_class?
              models << klass
            rescue NameError, LoadError
              # Not a valid model class
            end
          end
        end

        models.uniq.sort_by(&:name)
      end

      def extract_model_details(model)
        # AST-based source introspection (replaces all regex parsing)
        source_data = introspect_source(model)

        details = {
          table_name:       model.table_name,
          # Reflection-based (runtime, most accurate for these)
          associations:     extract_associations(model),
          validations:      extract_validations(model),
          enums:            extract_enums(model),
          callbacks:        extract_callbacks(model, source_data),
          concerns:         extract_concerns(model),
          # AST-based (replaces regex source parsing)
          custom_validates: extract_custom_validates_from_ast(source_data),
          scopes:           extract_scopes_from_ast(source_data),
          class_methods:    extract_class_methods_from_ast(model, source_data),
          instance_methods: extract_instance_methods_from_ast(model, source_data)
        }

        sti_info = extract_sti_info(model)
        details[:sti] = sti_info if sti_info

        # AST-based enum options (replaces regex)
        enum_options = extract_enum_options_from_ast(source_data)
        details[:enum_options] = enum_options if enum_options.any?

        # AST-based macro extractions (replaces regex)
        macros = extract_macros_from_ast(source_data, model_source_path(model))
        details.merge!(macros)

        # AST-based detailed macros (replaces regex)
        detailed = extract_detailed_macros_from_ast(source_data)
        details.merge!(detailed)

        details.compact
      end

      # Run SourceIntrospector on the model's source file.
      # Returns the full AST introspection result or empty hash.
      def introspect_source(model)
        path = model_source_path(model)
        return empty_source_data unless path && File.exist?(path)
        return empty_source_data if File.size(path) > RailsAiContext.configuration.max_file_size

        SourceIntrospector.call(path)
      rescue => e
        $stderr.puts "[rails-ai-context] AST introspection failed for #{model.name}: #{e.message}" if ENV["DEBUG"]
        empty_source_data
      end

      def empty_source_data
        { associations: [], validations: [], scopes: [], enums: [], callbacks: [], macros: [], methods: [] }
      end

      # ── Reflection-based extraction (unchanged) ─────────────────────

      def extract_associations(model)
        excluded = config.excluded_association_names
        model.reflect_on_all_associations.reject { |assoc| excluded.include?(assoc.name.to_s) }.map do |assoc|
          detail = {
            name: assoc.name.to_s,
            type: assoc.macro.to_s,
            class_name: assoc.class_name,
            foreign_key: assoc.foreign_key.to_s
          }
          detail[:through]    = assoc.options[:through].to_s if assoc.options[:through]
          detail[:polymorphic] = true if assoc.options[:polymorphic]
          detail[:dependent]  = assoc.options[:dependent].to_s if assoc.options[:dependent]
          detail[:optional]   = assoc.options[:optional] if assoc.options.key?(:optional)
          detail.compact
        end
      end

      def extract_validations(model)
        model.validators.map do |validator|
          {
            kind: validator.kind.to_s,
            attributes: validator.attributes.map(&:to_s),
            options: sanitize_options(validator.options)
          }
        end
      end

      def extract_enums(model)
        return {} unless model.respond_to?(:defined_enums)
        model.defined_enums.transform_values { |mapping| mapping.dup }
      end

      def extract_concerns(model)
        model.ancestors
          .select { |mod| mod.is_a?(Module) && !mod.is_a?(Class) }
          .reject { |mod| framework_concern?(mod.name) }
          .map(&:name)
          .compact
      end

      def extract_sti_info(model)
        has_type_column = if model.connected? && model.table_exists?
          model.columns_hash.key?("type")
        else
          schema_path = File.join(app.root.to_s, "db", "schema.rb")
          if File.exist?(schema_path)
            schema = RailsAiContext::SafeFile.read(schema_path)
            table_section = schema[/create_table\s+"#{Regexp.escape(model.table_name)}".*?end/m]
            table_section&.match?(/t\.\w+\s+"type"/)
          end
        end

        return nil unless has_type_column

        children = if model.respond_to?(:descendants)
          model.descendants.map(&:name).compact.sort
        elsif model.respond_to?(:subclasses)
          model.subclasses.map(&:name).compact.sort
        else
          []
        end

        parent = model.superclass
        sti_parent = if parent && parent != ActiveRecord::Base &&
                        (!defined?(ApplicationRecord) || parent != ApplicationRecord)
          parent.name
        end

        {
          sti_base: sti_parent.nil? && children.any?,
          sti_parent: sti_parent,
          sti_children: children.empty? ? nil : children
        }.compact
      rescue => e
        $stderr.puts "[rails-ai-context] extract_sti_info failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def extract_callbacks(model, source_data)
        callback_types = %i[
          before_validation after_validation
          before_save after_save
          before_create after_create
          before_update after_update
          before_destroy after_destroy
          after_commit after_rollback
        ]

        result = callback_types.each_with_object({}) do |type, hash|
          callbacks = model.send(:"_#{type}_callbacks").reject do |cb|
            cb.filter.nil? || cb.filter.to_s.start_with?(*EXCLUDED_CALLBACKS) || cb.filter.is_a?(Proc)
          end

          next if callbacks.empty?

          hash[type.to_s] = callbacks.map { |cb| cb.filter.to_s }
        end

        # If reflection returned nothing, fall back to AST-based extraction
        return result if result.any?
        extract_callbacks_from_ast(source_data)
      rescue => e
        $stderr.puts "[rails-ai-context] extract_callbacks failed: #{e.message}" if ENV["DEBUG"]
        extract_callbacks_from_ast(source_data)
      end

      # ── AST-based extraction (replaces all regex parsing) ──────────

      def extract_scopes_from_ast(source_data)
        source_data[:scopes].map { |s| { name: s[:name], body: s[:body] } }
      end

      def extract_custom_validates_from_ast(source_data)
        source_data[:validations]
          .select { |v| v[:kind] == :custom }
          .flat_map { |v| v[:attributes] }
      end

      def extract_enum_options_from_ast(source_data)
        source_data[:enums].each_with_object({}) do |enum, opts|
          entry = {}
          entry[:prefix] = enum[:options][:prefix] || enum[:options][:_prefix] if enum[:options][:prefix] || enum[:options][:_prefix]
          entry[:suffix] = enum[:options][:suffix] || enum[:options][:_suffix] if enum[:options][:suffix] || enum[:options][:_suffix]
          opts[enum[:name]] = entry if entry.any?
        end
      end

      def extract_callbacks_from_ast(source_data)
        source_data[:callbacks].each_with_object({}) do |cb, hash|
          type = cb[:type].to_s
          (hash[type] ||= []) << cb[:method]
        end
      end

      def extract_class_methods_from_ast(model, source_data)
        # Scope names to exclude from class methods (they appear in :scopes already)
        scope_names = source_data[:scopes].map { |s| s[:name].to_s }.to_set

        # Source-defined class methods (AST)
        source_methods = source_data[:methods]
          .select { |m| m[:scope] == :class && m[:visibility] == :public }
          .map { |m| m[:name] }
          .reject { |m| scope_names.include?(m) }

        # Reflection-discovered class methods (for completeness)
        all_methods = (model.methods - ActiveRecord::Base.methods - Object.methods)
          .reject { |m|
            ms = m.to_s
            ms == "self" ||
              ms.start_with?("_", "autosave") ||
              scope_names.include?(ms) ||
              DEVISE_CLASS_METHOD_PATTERNS.include?(ms) ||
              ms.end_with?("=") && ms.length > 20
          }
          .map(&:to_s)
          .sort

        # Source-defined methods first, then reflection-discovered ones
        ordered = source_methods + (all_methods - source_methods)
        ordered.first(30)
      end

      def extract_instance_methods_from_ast(model, source_data)
        generated = generated_association_methods(model)

        # Source-defined instance methods (AST)
        source_methods = source_data[:methods]
          .select { |m| m[:scope] == :instance && m[:visibility] == :public }
          .map { |m| m[:name] }

        # Reflection-discovered instance methods
        all_methods = (model.instance_methods - ActiveRecord::Base.instance_methods - Object.instance_methods)
          .reject { |m|
            ms = m.to_s
            ms.start_with?("_", "autosave", "validate_associated") ||
              generated.include?(ms) ||
              DEVISE_INSTANCE_PATTERNS.include?(ms) ||
              ms.match?(/\Awill_save_change_to_|_before_last_save\z|_in_database\z|_before_type_cast\z/)
          }
          .map(&:to_s)
          .sort

        # Source-defined methods first
        ordered = source_methods + (all_methods - source_methods)
        ordered.first(30)
      end

      # Maps macro names to their target key in the output hash.
      # Each entry collects m[:attribute] into an array under that key.
      ATTRIBUTE_MACRO_MAP = {
        encrypts: :encrypts,
        normalizes: :normalizes,
        has_one_attached: :has_one_attached,
        has_many_attached: :has_many_attached,
        has_rich_text: :has_rich_text,
        generates_token_for: :generates_token_for,
        serialize: :serialize,
        store: :store,
        store_accessor: :store
      }.freeze

      BROADCAST_MACROS = %i[broadcasts broadcasts_to broadcasts_refreshes_to].to_set.freeze

      def extract_macros_from_ast(source_data, source_path = nil)
        macros = {}
        source_data[:macros].each do |m|
          macro = m[:macro]

          if macro == :has_secure_password
            macros[:has_secure_password] = true
          elsif (key = ATTRIBUTE_MACRO_MAP[macro])
            (macros[key] ||= []) << m[:attribute]
          elsif macro == :delegate
            (macros[:delegations] ||= []) << { methods: m[:methods], to: m[:to] }
          elsif macro == :delegate_missing_to
            macros[:delegate_missing_to] = m[:to]
          elsif macro == :attribute
            (macros[:attributes] ||= []) << { name: m[:attribute], type: m[:type] }.compact
          end

          if BROADCAST_MACROS.include?(macro)
            (macros[:broadcasts] ||= []) << macro.to_s
            macros[:broadcasts].uniq!
          end
        end

        constants = extract_constants_from_source(source_path)
        macros[:constants] = constants if constants&.any?

        macros.reject { |_, v| v.is_a?(Array) && v.empty? }
      end

      # Extract constant definitions from source using regex.
      # Prism constant assignment detection needs a different visitor pattern
      # and constants are trivial, so regex is appropriate here.
      def extract_constants_from_source(source_path)
        return nil unless source_path && File.exist?(source_path)

        source = RailsAiContext::SafeFile.read(source_path)
        return nil unless source

        source.scan(/\b([A-Z][A-Z_]+)\s*=\s*%[wi]\[([^\]]+)\]/).map do |name, values|
          { name: name, values: values.split }
        end
      end

      def extract_detailed_macros_from_ast(source_data)
        encryption = []
        normalizations = []
        tokens = []

        source_data[:macros].each do |m|
          case m[:macro]
          when :encrypts
            opts = {}
            opts[:deterministic] = true if m[:options][:deterministic] == true
            opts[:downcase] = true if m[:options][:downcase] == true
            encryption << { field: m[:attribute], options: opts }
          when :normalizes
            entry = { field: m[:attribute] }
            entry[:transformation] = m[:options][:with].to_s if m[:options][:with]
            normalizations << entry.compact
          when :generates_token_for
            entry = { purpose: m[:attribute] }
            entry[:expires_in] = m[:options][:expires_in].to_s if m[:options][:expires_in]
            tokens << entry.compact
          end
        end

        macros = {}
        macros[:encryption_details] = encryption if encryption.any?
        macros[:normalizes_details] = normalizations if normalizations.any?
        macros[:token_generation] = tokens if tokens.any?
        macros
      end

      # ── Helpers ────────────────────────────────────────────────────

      def model_source_path(model)
        root = app.root.to_s
        underscored = model.name.underscore
        File.join(root, "app", "models", "#{underscored}.rb")
      end

      def framework_concern?(name)
        return true if name.nil?
        return true if %w[Kernel JSON PP Marshal MessagePack].any? { |prefix| name == prefix || name.start_with?("#{prefix}::") }
        return true if name.start_with?("ActiveModel::", "ActiveRecord::", "ActiveSupport::")
        RailsAiContext.configuration.excluded_concerns.any? { |pattern| name.match?(pattern) }
      end

      DEVISE_CLASS_METHOD_PATTERNS = %w[
        authentication_keys= case_insensitive_keys= strip_whitespace_keys=
        reset_password_keys= confirmation_keys= unlock_keys=
        email_regexp= password_length= timeout_in= remember_for=
        sign_in_after_reset_password= sign_in_after_change_password=
        reconfirmable= extend_remember_period= pepper=
        stretches= allow_unconfirmed_access_for=
        confirm_within= remember_for= unlock_in=
        lock_strategy= unlock_strategy= maximum_attempts=
        paranoid= last_attempt_warning=
      ].to_set.freeze

      DEVISE_INSTANCE_PATTERNS = %w[
        password_required? email_required? confirmation_required?
        active_for_authentication? inactive_message authenticatable_salt
        after_database_authentication send_devise_notification
        send_confirmation_instructions send_reset_password_instructions
        send_unlock_instructions send_on_create_confirmation_instructions
        devise_mailer clean_up_passwords skip_confirmation!
        skip_reconfirmation! valid_password? update_with_password
        destroy_with_password remember_me! forget_me!
        unauthenticated_message confirmation_period_valid?
        pending_reconfirmation? reconfirmation_required?
        send_email_changed_notification send_password_change_notification
      ].to_set.freeze

      def generated_association_methods(model)
        methods = []
        model.reflect_on_all_associations.each do |assoc|
          name = assoc.name.to_s
          singular = name.singularize
          methods.concat(%W[
            build_#{name} create_#{name} create_#{name}!
            reload_#{name} reset_#{name}
            #{name}_changed? #{name}_previously_changed?
            #{singular}_ids #{singular}_ids=
          ])
        end
        methods
      rescue => e
        $stderr.puts "[rails-ai-context] generated_association_methods failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def sanitize_options(options)
        options.reject { |_k, v| v.is_a?(Proc) || v.is_a?(Regexp) }
               .transform_values(&:to_s)
      end
    end
  end
end
