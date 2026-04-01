# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts ActiveRecord model metadata: associations, validations,
    # scopes, enums, callbacks, and class-level configuration.
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

        # Use targeted eager_load_dir to pick up newly created model files
        models_path = File.join(app.root, "app", "models")
        if defined?(Zeitwerk) && Dir.exist?(models_path) &&
           Rails.autoloaders.respond_to?(:main) && Rails.autoloaders.main.respond_to?(:eager_load_dir)
          Rails.autoloaders.main.eager_load_dir(models_path)
        else
          Rails.application.eager_load!
        end
      rescue
        # In some environments (CI, Claude Code) eager_load may partially fail
        nil
      end

      def discover_models
        return [] unless defined?(ActiveRecord::Base)

        models = ActiveRecord::Base.descendants.reject do |model|
          model.abstract_class? ||
            model.name.nil? ||
            config.excluded_models.include?(model.name)
        end

        # Filesystem fallback — discover model files not yet loaded by descendants
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
        details = {
          table_name: model.table_name,
          associations: extract_associations(model),
          validations: extract_validations(model),
          custom_validates: extract_custom_validates(model),
          scopes: extract_scopes(model),
          enums: extract_enums(model),
          callbacks: extract_callbacks(model),
          concerns: extract_concerns(model),
          class_methods: extract_public_class_methods(model),
          instance_methods: extract_public_instance_methods(model)
        }

        # Source-based macro extractions
        macros = extract_source_macros(model)
        details.merge!(macros)

        # Detailed macro extractions (field + options)
        detailed = extract_detailed_macros(model)
        details.merge!(detailed)

        details.compact
      end

      def extract_associations(model)
        model.reflect_on_all_associations.map do |assoc|
          detail = {
            name: assoc.name.to_s,
            type: assoc.macro.to_s, # :has_many, :belongs_to, :has_one, :has_and_belongs_to_many
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

      def extract_scopes(model)
        source_path = model_source_path(model)
        return [] unless source_path && File.exist?(source_path)

        source = File.read(source_path)
        source.scan(/^\s*scope\s+:(\w+)\s*,\s*->\s*(?:\([^)]*\)\s*)?\{([^}]*)\}/m).map do |name, body|
          { name: name, body: body.strip }
        end
      rescue
        []
      end

      # Extract custom validate :method_name calls from source
      # These are business-rule validators that model.validators doesn't include
      def extract_custom_validates(model)
        source_path = model_source_path(model)
        return [] unless source_path && File.exist?(source_path)

        File.read(source_path).scan(/^\s*validate\s+:(\w+)/).flatten
      rescue
        []
      end

      def model_source_path(model)
        root = app.root.to_s
        underscored = model.name.underscore
        File.join(root, "app", "models", "#{underscored}.rb")
      end

      def extract_enums(model)
        return {} unless model.respond_to?(:defined_enums)

        model.defined_enums.transform_values { |mapping| mapping.dup }
      end

      def extract_callbacks(model)
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
            cb.filter.to_s.start_with?(*EXCLUDED_CALLBACKS) || cb.filter.is_a?(Proc)
          end

          next if callbacks.empty?

          hash[type.to_s] = callbacks.map { |cb| cb.filter.to_s }
        end

        # If reflection returned nothing, fall back to source parsing
        return result if result.any?
        extract_callbacks_from_source(model)
      rescue
        extract_callbacks_from_source(model)
      end

      # Parse callback declarations from model source file
      def extract_callbacks_from_source(model)
        source_path = model_source_path(model)
        return {} unless source_path && File.exist?(source_path)

        source = File.read(source_path)
        callbacks = {}
        source.each_line do |line|
          if (match = line.match(/\A\s*(before_validation|after_validation|before_save|after_save|before_create|after_create|before_update|after_update|before_destroy|after_destroy|after_commit|after_rollback)\s+:(\w+)/))
            type = match[1]
            method_name = match[2]
            (callbacks[type] ||= []) << method_name
          end
        end
        callbacks
      rescue
        {}
      end

      def extract_concerns(model)
        model.ancestors
          .select { |mod| mod.is_a?(Module) && !mod.is_a?(Class) }
          .reject { |mod| framework_concern?(mod.name) }
          .map(&:name)
          .compact
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

      def extract_public_class_methods(model)
        scope_names = extract_scopes(model).map { |s| s.is_a?(Hash) ? s[:name].to_s : s.to_s }

        # Prioritize methods defined in the model's own source file
        source_methods = extract_source_class_methods(model)

        all_methods = (model.methods - ActiveRecord::Base.methods - Object.methods)
          .reject { |m|
            ms = m.to_s
            ms == "self" ||
              ms.start_with?("_", "autosave") ||
              scope_names.include?(ms) ||
              DEVISE_CLASS_METHOD_PATTERNS.include?(ms) ||
              ms.end_with?("=") && ms.length > 20 # Devise setter-like methods
          }
          .map(&:to_s)
          .sort

        # Source-defined methods first, then reflection-discovered ones
        ordered = source_methods + (all_methods - source_methods)
        ordered.first(30)
      end

      def extract_source_class_methods(model)
        path = model_source_path(model)
        return [] unless path && File.exist?(path)

        source = File.read(path)
        methods = []
        in_class_methods = false
        source.each_line do |line|
          in_class_methods = true if line.match?(/\A\s*(?:class << self|def self\.)/)
          if line.match?(/\A\s*def self\.(\w+)/)
            methods << line.match(/def self\.(\w+)/)[1]
          end
          if in_class_methods && line.match?(/\A\s*def (\w+)/)
            methods << line.match(/def (\w+)/)[1]
          end
          in_class_methods = false if in_class_methods && line.match?(/\A\s*end\s*$/) && !line.match?(/def/)
        end
        methods.uniq
      rescue
        []
      end

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

      def extract_public_instance_methods(model)
        generated = generated_association_methods(model)

        # Prioritize source-defined methods
        source_methods = extract_source_instance_methods(model)

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

      def extract_source_instance_methods(model)
        path = model_source_path(model)
        return [] unless path && File.exist?(path)

        source = File.read(path)
        methods = []
        in_private = false
        source.each_line do |line|
          in_private = true if line.match?(/\A\s*private\s*$/)
          next if in_private
          next if line.match?(/\A\s*def self\./)
          if (match = line.match(/\A\s*def (\w+[?!]?)/))
            methods << match[1] unless match[1] == "initialize"
          end
        end
        methods.uniq
      rescue
        []
      end

      # Build list of AR-generated association helper method names to exclude
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
      rescue
        []
      end

      def extract_source_macros(model)
        path = model_source_path(model)
        return {} unless path && File.exist?(path)

        source = File.read(path)
        macros = {}

        macros[:has_secure_password] = true if source.match?(/\bhas_secure_password\b/)
        macros[:encrypts] = source.scan(/\bencrypts\s+(.+?)$/).flat_map { |m| m[0].scan(/:(\w+)/).flatten } if source.match?(/\bencrypts\s+:/)
        macros[:normalizes] = source.scan(/\bnormalizes\s+(.+?)$/).flat_map { |m| m[0].scan(/:(\w+)/).flatten } if source.match?(/\bnormalizes\s+:/)
        macros[:has_one_attached] = source.scan(/\bhas_one_attached\s+:(\w+)/).flatten if source.match?(/\bhas_one_attached\s+:/)
        macros[:has_many_attached] = source.scan(/\bhas_many_attached\s+:(\w+)/).flatten if source.match?(/\bhas_many_attached\s+:/)
        macros[:has_rich_text] = source.scan(/\bhas_rich_text\s+:(\w+)/).flatten if source.match?(/\bhas_rich_text\s+:/)
        macros[:broadcasts] = source.scan(/\b(broadcasts_to|broadcasts_refreshes_to|broadcasts)\b/).flatten.uniq if source.match?(/\bbroadcasts/)
        macros[:generates_token_for] = source.scan(/\bgenerates_token_for\s+:(\w+)/).flatten if source.match?(/\bgenerates_token_for\s+:/)
        macros[:serialize] = source.scan(/\bserialize\s+:(\w+)/).flatten if source.match?(/\bserialize\s+:/)
        macros[:store] = source.scan(/\bstore(?:_accessor)?\s+:(\w+)/).flatten if source.match?(/\bstore(?:_accessor)?\s+:/)

        # Constants with value lists (e.g. STATUSES = %w[pending completed])
        constants = source.scan(/\b([A-Z][A-Z_]+)\s*=\s*%[wi]\[([^\]]+)\]/).map do |name, values|
          { name: name, values: values.split }
        end
        macros[:constants] = constants if constants.any?

        # Delegations
        delegations = source.scan(/\bdelegate\s+(.+?),\s*to:\s*:(\w+)/m).map do |methods_str, target|
          { methods: methods_str.scan(/:(\w+)/).flatten, to: target }
        end
        macros[:delegations] = delegations if delegations.any?

        if (dmt = source.match(/\bdelegate_missing_to\s+:(\w+)/))
          macros[:delegate_missing_to] = dmt[1]
        end

        # Remove empty arrays
        macros.reject { |_, v| v.is_a?(Array) && v.empty? }
      rescue
        {}
      end

      def extract_detailed_macros(model)
        path = model_source_path(model)
        return {} unless path && File.exist?(path)

        source = File.read(path)
        macros = {}

        # encryption_details: encrypts :field, deterministic: true, downcase: true
        encryption = []
        source.each_line do |line|
          next unless line.match?(/\bencrypts\s+:/)
          fields = line.scan(/:(\w+)/).flatten
          opts_str = line.sub(/\bencrypts\s+/, "")
          options = {}
          options[:deterministic] = true if opts_str.match?(/deterministic:\s*true/)
          options[:downcase] = true if opts_str.match?(/downcase:\s*true/)
          fields.each do |field|
            # Skip option keywords that look like fields
            next if %w[deterministic downcase].include?(field)
            encryption << { field: field, options: options }
          end
        end
        macros[:encryption_details] = encryption if encryption.any?

        # normalizes_details: normalizes :field, with: -> { ... }
        normalizations = []
        source.each_line do |line|
          next unless line.match?(/\bnormalizes\s+:/)
          fields = line.scan(/:(\w+)/).flatten.reject { |f| f == "with" }
          transform_match = line.match(/with:\s*(->.+)$/)
          transformation = transform_match ? transform_match[1].strip : nil
          fields.each do |field|
            normalizations << { field: field, transformation: transformation }.compact
          end
        end
        macros[:normalizes_details] = normalizations if normalizations.any?

        # token_generation: generates_token_for :purpose, expires_in: 2.hours
        tokens = []
        source.each_line do |line|
          next unless line.match?(/\bgenerates_token_for\s+:/)
          purpose_match = line.match(/generates_token_for\s+:(\w+)/)
          next unless purpose_match
          expires_match = line.match(/expires_in:\s*([^\s,}]+(?:\.\w+)?)/)
          tokens << { purpose: purpose_match[1], expires_in: expires_match&.[](1) }.compact
        end
        macros[:token_generation] = tokens if tokens.any?

        macros
      rescue
        {}
      end

      def sanitize_options(options)
        # Remove procs and complex objects that don't serialize well
        options.reject { |_k, v| v.is_a?(Proc) || v.is_a?(Regexp) }
               .transform_values(&:to_s)
      end
    end
  end
end
