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
      extend StaticTier
      static_tier :alternate_source

      attr_reader :app, :config

      EXCLUDED_CALLBACKS = %w[autosave_associated_records_for].freeze

      def initialize(app)
        @app    = app
        @config = RailsAiContext.configuration
      end

      # @return [Hash] model metadata keyed by model name
      def call
        EagerLoad.dir(app.root, kind: "app/models")
        models = discover_models

        result = models.each_with_object({}) do |model, hash|
          hash[model.name] = extract_model_details(model)
        rescue => e
          hash[model.name] = { error: e.message }
        end

        # A hybrid app (ActiveRecord primary, Mongoid gem present too) has
        # documents that AR reflection can never see - they don't descend
        # from ActiveRecord::Base. Supplement rather than replace, so a
        # pure-AR model in a hybrid app keeps its full reflection-based
        # details instead of being reduced to Mongoid's blanket static pass.
        if RailsAiContext::AppKind.mongoid?(app.root)
          mongoid_static_models.each do |class_name, details|
            next if result.key?(class_name)
            next unless details[:mongoid]

            result[class_name] = details
          end
        end

        result
      end

      # Static tier: models are discovered by globbing every model directory
      # PathResolver resolves (conventional app/models, packs, engines, and
      # configured extras) and parsed with the source listeners; nothing is
      # constantized. The table comes from TableName over those same sources,
      # which is close to Rails but not the connection's own answer - a prefix
      # declared outside the model directories stays invisible - so every entry
      # is tagged STATIC rather than VERIFIED. When the same class name is
      # found in more than one directory, the first discovery wins.
      def static_call
        return mongoid_static_models if RailsAiContext::AppKind.mongoid?(app.root)

        candidates = static_candidates
        candidates.each_with_object({}) do |(class_name, candidate), result|
          if candidate[:error]
            result[class_name] = { error: candidate[:error] }
            next
          end

          # An abstract base is dropped from the result but not from the walk:
          # a per-connection base like Analytics::Record is how its models
          # reach ApplicationRecord.
          next if candidate[:abstract]
          next unless model_class?(class_name, candidates)

          result[class_name] = static_model_details(candidate[:path], class_name, file: candidate[:file],
                                                    table_name: resolve_table_name(class_name, candidates))
        end
      end

      private

      # Every class file under the model directories, by declared name, with
      # the superclass it names. Modelhood is decided over the whole walk
      # afterwards, because STI reaches its base through another file.
      #
      # The stat-only walk: SafeFile.read answers nil for both "too big" and
      # "cannot read it", and those are different answers. A model the
      # process cannot stat is an error entry rather than one that quietly
      # is not there. The count is an answer too.
      def static_candidates
        SourceScan.paths(app.root, kind: "app/models", skip_concerns: false).each_with_object({}) do |record, found|
          next if record.path_name == "ApplicationRecord"

          begin
            next if File.size(record.path) > RailsAiContext.configuration.max_file_size

            source = model_source(record.path)
            next if source.nil? || mixin_path?(record.path_name.underscore, source)

            declarations = DeclaredConstant.declarations(source)
            class_name = declarations.map(&:name).find { |name| name.casecmp?(record.path_name) } || record.path_name
            next if found.key?(class_name)
            next if config.excluded_models.include?(class_name)

            found[class_name] = {
              path: record.path,
              file: record.file,
              superclass: declarations.find { |d| d.name == class_name }&.superclass,
              abstract: abstract_class?(source),
              # A module file declares no class and is kept for these two
              # alone: they belong to the namespace, not to any one model.
              table_name: TableName.explicit(source, class_name),
              table_name_prefix: TableName.prefix(source, class_name),
              table_name_suffix: TableName.suffix(source, class_name)
            }
          rescue => e
            found[record.path_name] = { error: e.message }
          end
        end
      end

      # A model is a class whose superclass chain reaches a model base. A form
      # object, a filter or a namespaced calculator under app/models has no
      # superclass, or one the chain never resolves, so it is not a model.
      def model_class?(class_name, candidates, seen = [])
        return false if seen.include?(class_name)

        parent = candidates.dig(class_name, :superclass)
        return false unless parent
        return true if model_base?(parent)

        resolved = resolve_superclass(parent, class_name, candidates)
        return false unless resolved

        model_class?(resolved, candidates, seen + [ class_name ])
      end

      # ApplicationRecord, or the namespaced base a large app declares -
      # GitLab has Ci::ApplicationRecord and SecApplicationRecord.
      def model_base?(name)
        name == "ActiveRecord::Base" || name.split("::").last.end_with?("ApplicationRecord")
      end

      # Ruby resolves a bare superclass from the enclosing namespace outward,
      # so `Admin::Report < Post` means the top-level Post unless Admin
      # declares one.
      def resolve_superclass(name, from, candidates)
        return name if candidates.key?(name)

        scope = from.split("::")[0..-2]
        while scope.any?
          qualified = (scope + [ name ]).join("::")
          return qualified if candidates.key?(qualified)

          scope.pop
        end
        nil
      end

      # Rails' own order: what the class assigns itself wins, an STI child
      # reads its parent's table, and otherwise the namespace's prefix and
      # suffix wrap the stem the file name already carries.
      def resolve_table_name(class_name, candidates, seen = [])
        candidate = candidates[class_name]
        return nil unless candidate
        return candidate[:table_name] if candidate[:table_name]

        parent = sti_parent(class_name, candidates, seen)
        inherited = parent && resolve_table_name(parent, candidates, seen + [ class_name ])
        return inherited if inherited

        [ namespace_affix(class_name, candidates, :table_name_prefix),
          TableName.stem(candidate[:path]),
          namespace_affix(class_name, candidates, :table_name_suffix) ].join
      end

      # The model this one inherits its table from. A model base ends the
      # chain, and so does an abstract base: a child of one has a table of
      # its own.
      def sti_parent(class_name, candidates, seen)
        return nil if seen.include?(class_name)

        parent = candidates.dig(class_name, :superclass)
        return nil if parent.nil? || model_base?(parent)

        resolved = resolve_superclass(parent, class_name, candidates)
        return nil if resolved.nil? || candidates.dig(resolved, :abstract)

        resolved
      end

      # Rails takes the first of these its module parents answers, walking
      # innermost outward, so an inner namespace overrides an outer one.
      def namespace_affix(class_name, candidates, key)
        scope = class_name.split("::")[0..-2]
        while scope.any?
          declared = candidates.dig(scope.join("::"), key)
          return declared if declared

          scope.pop
        end
        ""
      end

      # Zeitwerk resolves a path through the app's own inflector, which the
      # static tier never loads, so camelizing invents `Activitypub::` for an
      # app that declares `ActivityPub::`.
      def declared_model_name(source, path_name)
        DeclaredConstant.resolve(source, path_name)
      end

      # The booted tier rejects `abstract_class?`, so the static tier must too
      # or the same app gets two model counts. A namespaced base is one of
      # these - GitLab has Ci::ApplicationRecord and SecApplicationRecord - and
      # the root application_record is not the only one to leave out.
      def abstract_class?(source)
        source.match?(/^[^\S\n]*self\.abstract_class\s*=\s*true/)
      end

      # `concerns/` under app/models is the Zeitwerk root for mixins: it does
      # not namespace its files, so the path is not their name. A nested
      # concerns/ is an ordinary namespace - OpenProject fills one with mixins,
      # but a class declared there is a model like any other.
      def mixin_path?(relative, source)
        segments = relative.split("/")
        return false unless segments.include?("concerns")
        return true if segments.first == "concerns"

        !DeclaredConstant.declares_class?(source)
      end

      # Rails names the anonymous join class it builds for a
      # has_and_belongs_to_many through a singleton `name=`, so it answers
      # "HABTM_Tags" while it lives at "Account::HABTM_Tags". A name that is
      # not the constant path belongs to no file and cannot key a payload -
      # two owners of the same association name collapse onto one entry.
      def renamed_class?(model)
        model.name != model.to_s
      end

      def discover_models
        return [] unless defined?(ActiveRecord::Base)

        models = ActiveRecord::Base.descendants.reject do |model|
          model.abstract_class? ||
            model.name.nil? ||
            renamed_class?(model) ||
            config.excluded_models.include?(model.name)
        end

        known = models.map(&:name).to_set
        # Concerns stay in: a nested concerns directory is a namespace, so a
        # class declared under one is a model and constantize sorts the mixins
        # out. A top-level `app/models/concerns` is an autoload root instead,
        # so its files declare no `Concerns::` prefix and that path name never
        # constantizes.
        SourceScan.paths(app.root, kind: "app/models", skip_concerns: false).each do |record|
          class_name = record.path_name
          next if class_name.start_with?("Concerns::")
          next if known.include?(class_name)
          next if config.excluded_models.include?(class_name)

          begin
            klass = class_name.constantize
            next unless klass < ActiveRecord::Base && !klass.abstract_class?
            models << klass
            known << class_name
          rescue NameError, LoadError, ScriptError
            # Not a valid (or currently loadable) model class - a
            # syntax-broken file costs itself, not the whole listing.
          end
        end

        models.uniq.sort_by(&:name)
      end

      def extract_model_details(model)
        # AST-based source introspection (replaces all regex parsing)
        own_source = introspect_source(model)
        # Reflection covers associations, validations and enums, but scopes,
        # macros and custom validates are read off the file - so the concerns
        # are merged here too, or the static tier out-answers this one.
        source_data, = merge_concern_macros(own_source, model.name)

        details = {
          table_name:       model.table_name,
          file:             relative_to_root(model_source_path(model)),
          # Reflection-based (runtime, most accurate for these)
          associations:     extract_associations(model),
          validations:      extract_validations(model),
          enums:            extract_enums(model),
          callbacks:        extract_callbacks(model, source_data),
          concerns:         extract_concerns(model),
          concern_callbacks: concern_callbacks(source_data[:callbacks]),
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
        # The reject stays ahead of the map: class_name/foreign_key on an
        # excluded reflection with a broken :through raises, and `call`'s
        # per-model rescue would replace the whole model with one error line.
        model.reflect_on_all_associations.reject { |assoc| excluded_association?(assoc.name) }.map do |assoc|
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
            # `validates_with` registers a bare ActiveModel::Validator, which
            # has no #attributes - only EachValidator does. Calling it blind
            # replaced the whole model's answer with one error line.
            attributes: validator.respond_to?(:attributes) ? Array(validator.attributes).map(&:to_s) : [],
            options: sanitize_options(validator.options)
          }
        end
      end

      def extract_enums(model)
        return {} unless model.respond_to?(:defined_enums)
        model.defined_enums.transform_values { |mapping| mapping.dup }
      end

      def extract_concerns(model)
        ConcernMembership.from_ancestors(model)
      end

      def extract_sti_info(model)
        has_type_column = if model.connected? && model.table_exists?
          model.columns_hash.key?("type")
        else
          SchemaReader.for(app.root).column?(model.table_name, "type")
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

      # Rails registers one chain per event, holding before, after and around
      # together - there is no `_before_save_callbacks` and no separate around
      # chain, so the kind comes off the entry rather than the chain name.
      CALLBACK_EVENTS = %i[validation save create update destroy touch commit rollback initialize find].freeze

      def extract_callbacks(model, source_data)
        result = CALLBACK_EVENTS.each_with_object({}) do |event, hash|
          chain = :"_#{event}_callbacks"
          next unless model.respond_to?(chain, true)

          model.send(chain).each do |cb|
            next if cb.filter.nil? || cb.filter.to_s.start_with?(*EXCLUDED_CALLBACKS) || cb.filter.is_a?(Proc)

            (hash["#{cb.kind}_#{event}"] ||= []) << cb.filter.to_s
          end
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
        source_data[:scopes].map do |s|
          {
            name: s[:name],
            body: s[:body],
            required_params: s[:required_params] || [],
            confidence: s[:confidence]
          }.compact
        end
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
        group_callbacks_by_type(source_data[:callbacks])
      end

      # One shape for both tiers: { "before_validation" => ["normalize"] }.
      def group_callbacks_by_type(callbacks)
        Array(callbacks).each_with_object({}) do |cb, hash|
          next unless cb.is_a?(Hash) && cb[:type]

          (hash[cb[:type].to_s] ||= []) << cb[:method]
        end
      end

      def extract_class_methods_from_ast(model, source_data)
        # Scope names to exclude from class methods (they appear in :scopes already)
        scope_names = source_data[:scopes].map { |s| s[:name].to_s }.to_set

        # Source-defined class methods (AST), the model's own - a class nested
        # in the model file is a separate owner.
        source_methods = ActionResolver.own_methods(source_data[:methods], model.name)
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

        # Source-defined instance methods (AST), the model's own.
        source_methods = ActionResolver.own_methods(source_data[:methods], model.name)
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

      # Extract constant definitions from source via AST.
      # Finds ConstantWriteNode where the value is an ArrayNode
      # (covers %w[], %i[], and literal array forms).
      def extract_constants_from_source(source_path)
        return nil unless source_path && File.exist?(source_path)

        parse_result = AstCache.parse(source_path)
        constants = []
        find_constant_arrays(parse_result.value, constants)
        constants.empty? ? nil : constants
      end

      def find_constant_arrays(node, constants)
        case node
        when Prism::ConstantWriteNode
          name = node.name.to_s
          # Only capture UPPER_CASE constants (matching the old regex behavior)
          if name.match?(/\A[A-Z][A-Z_]+\z/)
            # Unwrap .freeze if present: STATUSES = %w[...].freeze
            value_node = node.value
            value_node = value_node.receiver if value_node.is_a?(Prism::CallNode) && value_node.name == :freeze

            if value_node.is_a?(Prism::ArrayNode)
              values = value_node.elements.filter_map { |el|
                case el
                when Prism::StringNode then el.unescaped
                when Prism::SymbolNode then el.value
                else nil
                end
              }
              constants << { name: name, values: values } if values.any?
            end
          end
        end
        node.child_nodes.compact.each { |child| find_constant_arrays(child, constants) }
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

      # Ruby knows where the class was defined, and the name does not: a model
      # in a pack or engine does not live under app/models, and an inflected
      # namespace does not underscore back to its own directory. The
      # containment check keeps a gem-defined constant from being reported as
      # the app's own file.
      def model_source_path(model)
        root = app.root.to_s
        located = Object.const_source_location(model.name)&.first
        return located if located && File.expand_path(located).start_with?("#{File.expand_path(root)}/")

        File.join(root, "app", "models", "#{model.name.underscore}.rb")
      rescue NameError, TypeError
        File.join(root, "app", "models", "#{model.name.underscore}.rb")
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

      # The listener names an association with a Symbol and reflection with a
      # String, so the key is compared as text on both tiers.
      def excluded_association?(name)
        config.excluded_association_names.include?(name.to_s)
      end

      def reject_excluded_associations(associations)
        Array(associations).reject { |assoc| excluded_association?(assoc[:name]) }
      end

      def sanitize_options(options)
        options.reject { |_k, v| v.is_a?(Proc) || v.is_a?(Regexp) }
               .transform_values(&:to_s)
      end

      def static_model_details(path, class_name, file: relative_to_root(path), table_name: nil)
        own = SourceIntrospector.call(path)
        data, unread = merge_concern_macros(own, class_name)
        details = {
          confidence: Confidence::STATIC,
          table_name: table_name || TableName.stem(path),
          associations: reject_excluded_associations(data[:associations]),
          validations: data[:validations],
          custom_validates: extract_custom_validates_from_ast(data),
          scopes: data[:scopes],
          # The booted tier answers a Hash of attribute => value map, and
          # every renderer destructures one; the listener's records are a
          # different shape under the same key.
          enums: static_enums(data[:enums]),
          # Same shape as the booted tier: a Hash keyed by callback type. The
          # listener hands back a flat Array, and every consumer filters on
          # `callbacks.is_a?(Hash)` - so passing it through rendered "No models
          # with callbacks found" and then raised a TypeError on a Hash lookup
          # against an Array.
          callbacks: group_callbacks_by_type(data[:callbacks]),
          concerns: static_concerns(own[:mixins]),
          concern_callbacks: concern_callbacks(data[:callbacks]),
          concerns_unread: (unread if unread.any?),
          macros: data[:macros],
          methods: ActionResolver.own_methods(own[:methods], class_name),
          file: file
        }
        details.merge!(extract_macros_from_ast(data, path))
        details.merge!(extract_detailed_macros_from_ast(data))
        details.compact
      end

      MERGED_CONCERN_KEYS = %i[associations validations scopes enums callbacks macros].freeze

      # The mixin names are in the same walk and their files are on disk, so
      # the class's own declarations and its concerns' answer as one. Methods
      # and mixins stay the model's own: those are its interface, not the
      # sum of what it included.
      def merge_concern_macros(own, class_name)
        collected, unread = ConcernMacros.collect(
          app.root.to_s, own[:mixins] || [],
          keys: MERGED_CONCERN_KEYS, prefer: "model", within: class_name
        )
        return [ own, unread ] if collected.empty?

        merged = own.merge(collected) { |_key, mine, inherited| Array(mine) + inherited }
        merged[:associations] = dedup(merged[:associations]) { |a| [ a[:type], a[:name] ] }
        merged[:scopes] = dedup(merged[:scopes]) { |s| s[:name] }
        [ merged, unread ]
      end

      # The model's own declaration wins: it is the one whose options the
      # class actually runs with.
      def dedup(entries)
        Array(entries).uniq { |entry| entry.is_a?(Hash) ? yield(entry) : entry }
      end

      def concern_callbacks(callbacks)
        found = Array(callbacks).select { |cb| cb.is_a?(Hash) && cb[:from_concern] }
        found if found.any?
      end

      # `defined_enums` keys both levels with Strings; the listener uses
      # Symbols, and a consumer that looks a value up by name misses.
      def static_enums(enums)
        Array(enums).each_with_object({}) do |enum, hash|
          values = enum[:values]
          hash[enum[:name].to_s] = values.is_a?(Hash) ? values.transform_keys(&:to_s) : values
        end
      end

      # Consumers used to turn a model name back into
      # app/models/<underscored>.rb, which is wrong for a model in a pack or an
      # engine and wrong wherever the app registers an inflection. The path
      # travels with the model instead.
      def relative_to_root(path)
        path.to_s.sub(%r{\A#{Regexp.escape(app.root.to_s)}/}, "")
      end

      # This sees the model file alone, where the booted tier also walks what
      # its superclass and its concerns pulled in.
      def static_concerns(mixins)
        ConcernMembership.from_mixins(mixins)
      end

      # Mongoid documents are invisible to ActiveRecord reflection, so both
      # tiers parse them from source. Fields and embedded relations come from
      # the Mongoid listener; shared-name macros (belongs_to, has_many,
      # validates, scope) come from the regular listener stack.
      def mongoid_static_models
        RailsAiContext::PathResolver.model_dirs(app.root).each_with_object({}) do |models_dir, result|
          Dir.glob(File.join(models_dir, "**", "*.rb")).sort.each do |path|
            relative = path.sub("#{models_dir}/", "").sub(/\.rb\z/, "")
            next if relative == "application_record"

            begin
              next if File.size(path) > RailsAiContext.configuration.max_file_size

              source = model_source(path)
              next if source.nil? || mixin_path?(relative, source) || abstract_class?(source)

              class_name = declared_model_name(source, relative.camelize)
              next if result.key?(class_name)
              next if config.excluded_models.include?(class_name)

              result[class_name] = if source.include?("Mongoid::Document")
                mongoid_model_details(path).merge(file: relative_to_root(path))
              else
                # This walk keeps no candidate hash, so an AR model in a
                # hybrid app gets the table it assigns itself and the derived
                # stem otherwise - no namespace prefix, no STI parent.
                static_model_details(path, class_name, table_name: TableName.explicit(source, class_name))
              end
            rescue => e
              result[relative.camelize] = { error: e.message }
            end
          end
        end
      end

      # The file's source, or nil when it is unreadable or over the size cap.
      # One read feeds the name, the mixin test and - in a hybrid app, where
      # AR-backed models sit under the same directories as real documents -
      # the Mongoid::Document test that picks the listener stack.
      def model_source(path)
        RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_file_size)
      end

      def mongoid_model_details(path)
        data = SourceIntrospector.walk(path, {
          mongoid: -> { Listeners::MongoidFieldsListener.new },
          associations: Listeners::AssociationsListener,
          validations: Listeners::ValidationsListener,
          scopes: Listeners::ScopesListener,
          callbacks: Listeners::CallbacksListener,
          methods: Listeners::MethodsListener
        })
        macros = data[:mongoid] || []
        details = {
          confidence: Confidence::STATIC,
          mongoid: true,
          fields: macros.select { |m| m[:macro] == :field }
                        .map { |m| { name: m[:args].first, type: m[:options][:type] }.compact },
          embeds: macros.select { |m| %i[embeds_many embeds_one embedded_in].include?(m[:macro]) }
                        .map { |m| { type: m[:macro], name: m[:args].first } },
          associations: reject_excluded_associations(data[:associations]),
          validations: data[:validations],
          scopes: data[:scopes],
          # Same shape as the booted tier: a Hash keyed by callback type. The
          # listener hands back a flat Array, and every consumer filters on
          # `callbacks.is_a?(Hash)` - so passing it through rendered "No models
          # with callbacks found" and then raised a TypeError on a Hash lookup
          # against an Array.
          callbacks: group_callbacks_by_type(data[:callbacks]),
          methods: data[:methods]
        }
        collection = macros.find { |m| m[:macro] == :store_in }&.dig(:options, :collection)
        details[:collection] = collection if collection
        details
      end
    end
  end
end
