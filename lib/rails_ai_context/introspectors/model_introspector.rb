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

      def initialize(app)
        @app    = app
        @config = RailsAiContext.configuration
        # One introspection per file per instance, so a concern or an STI base
        # shared by 100 models is walked once. Anything longer-lived would
        # outlast the files it read.
        @source_cache = {}
      end

      # @return [Hash] model metadata keyed by model name
      def call
        EagerLoad.dir(app.root, kind: "app/models")
        @unloadable = {}
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

        unloadable_models.each { |class_name, details| result[class_name] ||= details }

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
        sti_parents = candidates.keys.to_h { |name| [ name, sti_parent(name, candidates, []) ] }
        bases = declared_bases(candidates)
        candidates.each_with_object({}) do |(class_name, candidate), result|
          # Hidden from the listing, kept in the walk: its children still
          # inherit its table and its declarations.
          next if config.excluded_models.include?(class_name)

          if candidate[:error]
            result[class_name] = { error: candidate[:error], file: candidate[:file] }.compact
            next
          end

          if candidate[:unreadable]
            # app/models holds POROs too, and a file the walk could not read
            # might be one. The entry says what it knows and claims a table
            # only where a child's inheritance says it is a model.
            table = resolve_table_name(class_name, candidates) if bases.include?(class_name)
            result[class_name] = { error: candidate[:unreadable], file: candidate[:file],
                                   table_name: table }.compact
            next
          end

          # An abstract base is dropped from the result and kept in the walk:
          # it is not a model of the app, and it is how its children reach what
          # it declares.
          next if candidate[:abstract]
          next unless model_class?(class_name, candidates)

          # Resolved before the details, so the rescue below states it rather
          # than calling again: a second raise from the same call would escape
          # the rescue meant to contain the first.
          table = resolve_table_name(class_name, candidates)
          result[class_name] = static_model_details(candidate[:path], class_name, file: candidate[:file],
                                                    table_name: table,
                                                    inherited_from: declaring_bases(class_name, candidates),
                                                    sti: static_sti_info(class_name, sti_parents))
        rescue => e
          # What the booted tier does with a model that raises: the entry says
          # so and the rest of the section still answers. It keeps the two
          # facts the unreadable branch keeps, because a consumer with no file
          # derives app/models/<name>.rb, which is a path a pack model does
          # not have.
          result[class_name] = { error: e.message, file: candidate[:file], table_name: table }.compact
        end
      end

      private

      # The same shape the booted tier reports under :sti, off the chain the
      # static tier already resolves to share the base's table. A model that
      # inherits from another model IS the STI relation, so no type column has
      # to be read to name it.
      def static_sti_info(class_name, sti_parents)
        parent = sti_parents[class_name]
        children = sti_parents.select { |_name, other_parent| other_parent == class_name }.keys.sort

        return nil if parent.nil? && children.empty?

        {
          sti_base: parent.nil? && children.any?,
          sti_parent: parent,
          sti_children: (children unless children.empty?)
        }.compact
      end

      # A model file the app cannot load leaves its class out of reflection,
      # and leaving it out here answers that the model does not exist and that
      # its table has no model at all. The file is a fact the source walk
      # already holds, so the name is kept with the load error and with the
      # table the static tier reads off that same file.
      def unloadable_models
        return {} if @unloadable.nil? || @unloadable.empty?

        candidates = static_candidates
        @unloadable.each_with_object({}) do |(class_name, error), entries|
          candidate = candidates[class_name]
          entries[class_name] = {
            error: error,
            file: candidate&.dig(:file),
            table_name: candidate && resolve_table_name(class_name, candidates)
          }.compact
        end
      end

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
          begin
            source = model_source(record.path) if File.size(record.path) <= RailsAiContext.configuration.max_file_size
            if source.nil?
              found[record.path_name] ||= unread_candidate(record) unless skip_unread?(record)
              next
            end

            next if mixin_path?(record.path_name.underscore, source)

            declarations = DeclaredConstant.declarations(source)
            class_name = declarations.map(&:name).find { |name| name.casecmp?(record.path_name) } || record.path_name
            next if found.key?(class_name)

            # A module file declares no class and is kept for the prefix and
            # the suffix alone: they belong to the namespace, not to any one
            # model.
            found[class_name] = {
              path: record.path,
              file: record.file,
              superclass: declarations.find { |d| d.name == class_name }&.superclass,
              abstract: abstract_class?(source)
            }.merge(TableName.declarations(source, class_name))
          rescue => e
            # The file is known here whatever failed, and a consumer with none
            # derives app/models/<name>.rb, which a pack model does not have.
            found[record.path_name] = { error: e.message, file: record.file }.compact
          end
        end
      end

      # A file the walk could not read stays a candidate, because its children
      # reach ApplicationRecord through it and nothing else names their base.
      # It carries no superclass, so the entry says what happened instead of
      # answering the declarations it could not read.
      def unread_candidate(record)
        size = begin
          File.size(record.path)
        rescue SystemCallError
          nil
        end
        reason = if size && size > RailsAiContext.configuration.max_file_size
          "file is too large to read (#{size} bytes)"
        else
          "file is unreadable"
        end

        { path: record.path, file: record.file, unreadable: reason }
      end

      # Nothing distinguishes an unreadable concern from an unreadable model,
      # and a concern is not a model, so it stays out.
      def skip_unread?(record)
        record.path_name.underscore.split("/").include?("concerns")
      end

      # Every candidate another candidate inherits from, by the name the walk
      # resolves the superclass to.
      def declared_bases(candidates)
        candidates.each_with_object(Set.new) do |(name, candidate), found|
          parent = candidate[:superclass]
          next unless parent

          resolved = resolve_superclass(parent, name, candidates)
          found << resolved if resolved
        end
      end

      def model_class?(class_name, candidates, seen = [])
        return false if seen.include?(class_name)
        # A base under app/models that nobody can read is taken at its word:
        # refusing it would drop every child that reaches a model base only
        # through it.
        return true if candidates.dig(class_name, :unreadable)

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
        # An entry the walk recorded as an error carries no path, and a table
        # derived from no path is the empty string, which is truthy.
        return nil unless candidate && candidate[:path]
        return candidate[:table_name] if candidate[:table_name]

        parent = sti_parent(class_name, candidates, seen)
        inherited = parent && resolve_table_name(parent, candidates, seen + [ class_name ])
        return inherited unless inherited.nil? || inherited.empty?

        [ namespace_affix(class_name, candidates, :table_name_prefix),
          TableName.stem(candidate[:path]),
          namespace_affix(class_name, candidates, :table_name_suffix) ].join
      end

      # Every class this one inherits declarations from: the superclass chain
      # up to the model base, abstract bases included. Rails runs what an
      # abstract base declares in each of its children; only the table stops
      # there, which is what `sti_parent` answers. A base whose file the walk
      # could not name is skipped rather than ending the chain.
      def declaring_bases(class_name, candidates, seen = [])
        return [] if seen.include?(class_name)

        parent = candidates.dig(class_name, :superclass)
        return [] if parent.nil?

        # It ends at ActiveRecord::Base, which the app has no file for. The
        # app's own base does have one, and Rails runs what it declares in
        # every model, so the walk does not stop on the name.
        resolved = resolve_superclass(parent, class_name, candidates)
        return [] unless resolved && candidates.key?(resolved)

        inherited = declaring_bases(resolved, candidates, seen + [ class_name ])
        path = candidates.dig(resolved, :path)
        path ? [ [ resolved, path ] ] + inherited : inherited
      end

      # The same chain off the loaded class, abstract bases included: the
      # ancestor list reflection answers carries what they declared, so a walk
      # that stopped at one gave the two tiers different concerns for the same
      # child. A base whose file Ruby cannot place is skipped, not walked past,
      # because its own base's macros do not reach the child any other way.
      def booted_declaring_bases(model)
        return [] unless defined?(ActiveRecord::Base)

        dirs = PathResolver.model_dirs(app.root.to_s).map { |dir| "#{File.expand_path(dir)}/" }
        bases = []
        parent = model.superclass
        while parent.is_a?(Class) && parent < ActiveRecord::Base
          path = parent.name && model_source_path(parent)
          # The files the static walk reads, and no others. A gem's base is a
          # file that walk can never reach, so reading it here would answer a
          # scope the other tier cannot. Reflection still carries that base's
          # associations, validations and enums onto the child.
          bases << [ parent.name, path ] if path && File.exist?(path) && within?(path, dirs)
          parent = parent.superclass
        end
        bases
      end

      def within?(path, dirs)
        expanded = File.expand_path(path)
        dirs.any? { |dir| expanded.start_with?(dir) }
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
      # Rails takes the affix off the innermost namespace that declares one and
      # falls back to the class itself: `module_parents.detect { |p|
      # p.respond_to?(:table_name_prefix) } || self`.
      def namespace_affix(class_name, candidates, key)
        scope = class_name.split("::")[0..-2]
        while scope.any?
          declared = candidates.dig(scope.join("::"), key)
          return declared if declared

          scope.pop
        end
        candidates.dig(class_name, key) || ""
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
      # Both forms Rails accepts. A generated ApplicationRecord says
      # `primary_abstract_class`, so reading the assignment alone left the app's
      # own base looking like a model with a table.
      def abstract_class?(source)
        source.match?(/^[^\S\n]*self\.abstract_class\s*=\s*true/) ||
          source.match?(/^[^\S\n]*primary_abstract_class\b/)
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

      def discover_models
        return [] unless defined?(ActiveRecord::Base)

        models = ActiveRecord::Base.descendants.reject do |model|
          model.abstract_class? ||
            model.name.nil? ||
            DeclaredConstant.renamed?(model) ||
            config.excluded_models.include?(model.name)
        end

        known = models.map(&:name).to_set
        # Concerns stay in: a nested concerns directory is a namespace, so a
        # class declared under one is a model and constantize sorts the mixins
        # out. A top-level `app/models/concerns` is an autoload root instead,
        # so its files declare no `Concerns::` prefix and that path name never
        # constantizes.
        SourceScan.paths(app.root, kind: "app/models", skip_concerns: false).each do |record|
          next if record.path_name.start_with?("Concerns::")
          next if known.include?(record.path_name)
          next if config.excluded_models.include?(record.path_name)

          # The path does not name the class: an app inflection only changes
          # case, so activitypub/activity.rb camelizes to a constant the app
          # does not have and the file was listed as a model that will not
          # load. Read only where the camelized name is not already loaded, so
          # a booted run does not parse every model file to learn nothing.
          class_name = declared_model_name(model_source(record.path).to_s, record.path_name)
          next if known.include?(class_name)
          next if config.excluded_models.include?(class_name)

          begin
            klass = class_name.constantize
            next unless klass < ActiveRecord::Base && !klass.abstract_class?
            models << klass
            known << class_name
          rescue NameError, LoadError, ScriptError => e
            # A syntax-broken file costs itself, not the whole listing, but
            # its name is recorded: a file that exists for a class reflection
            # lacks is not the same answer as no such model.
            @unloadable[class_name] = e.message.to_s.lines.first.to_s.strip
          end
        end

        models.uniq.sort_by(&:name)
      end

      def extract_model_details(model)
        # AST-based source introspection (replaces all regex parsing)
        own_source = introspect_source(model)
        # Reflection covers associations, validations and enums, but scopes,
        # macros and custom validates are read off the file - so the concerns
        # and the superclasses are merged here too, or the static tier
        # out-answers this one.
        source_data, unread, hidden = merge_concern_macros(own_source, model.name)
        source_data, unread, bases_unread, hidden =
          merge_inherited_macros(source_data, unread, hidden, booted_declaring_bases(model))

        class_methods = extract_class_methods_from_ast(model, source_data)
        instance_methods = extract_instance_methods_from_ast(model, source_data)

        details = {
          table_name:       model.table_name,
          file:             relative_to_root(model_source_path(model)),
          # Reflection-based (runtime, most accurate for these)
          associations:     extract_associations(model),
          validations:      extract_validations(model),
          enums:            extract_enums(model),
          # Rails' event chains carry the framework's own registrations and
          # hold no block callbacks, so both tiers read the model's source.
          callbacks:        extract_callbacks_from_ast(source_data),
          concerns:         extract_concerns(model),
          concerns_hidden:  (hidden.size if hidden.any?),
          concern_callbacks: concern_callbacks(source_data[:callbacks]),
          concerns_unread:  (unread if unread.any?),
          bases_unread:     (bases_unread if bases_unread.any?),
          # AST-based (replaces regex source parsing)
          custom_validates: extract_custom_validates_from_ast(source_data),
          scopes:           extract_scopes_from_ast(source_data),
          class_methods:    class_methods.first(MAX_LISTED_METHODS),
          class_method_count: class_methods.size,
          instance_methods: instance_methods.first(MAX_LISTED_METHODS),
          instance_method_count: instance_methods.size
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
          association_detail(assoc)
        end
      end

      # One reflection that cannot resolve costs that reflection, not the
      # model. `class_name` on a `:through` whose through association does not
      # exist ends in `nil.klass`, and the per-model rescue in `call` then
      # replaced the whole model - its callbacks, its table heading, its node
      # in the graph - with a single error line.
      def association_detail(assoc)
        detail = {
          name: assoc.name.to_s,
          type: assoc.macro.to_s,
          class_name: assoc.class_name,
          foreign_key: assoc.foreign_key.to_s
        }
        detail[:through]    = assoc.options[:through].to_s if assoc.options[:through]
        # Read like `:optional` below: the static tier writes the value the
        # model declared, so writing only a truthy one here would give the
        # two tiers different keys for `polymorphic: false`.
        detail[:polymorphic] = assoc.options[:polymorphic] if assoc.options.key?(:polymorphic)
        detail[:dependent]  = assoc.options[:dependent].to_s if assoc.options[:dependent]
        detail[:optional]   = assoc.options[:optional] if assoc.options.key?(:optional)
        detail.compact
      rescue StandardError => e
        {
          name: assoc.name.to_s,
          type: assoc.macro.to_s,
          through: assoc.options[:through]&.to_s,
          unavailable: unresolvable_reason(assoc, e)
        }.compact
      end

      def unresolvable_reason(assoc, error)
        through = assoc.options[:through]
        owner = assoc.respond_to?(:active_record) ? assoc.active_record : nil
        if through && owner.respond_to?(:reflect_on_association) && owner.reflect_on_association(through).nil?
          "through :#{through} is not an association"
        else
          error.message
        end
      rescue StandardError
        error.message
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
        RailsAiContext.debug_fail(e, nil, label: "extract_sti_info")
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
          .select { |v| v[:kind] == "custom" }
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

      # What the payload lists. The count beside it is the whole set: a
      # consumer that reads the list as complete (diagnose did) states a
      # confident negative about a method the model defines.
      MAX_LISTED_METHODS = 30

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
        source_methods + (all_methods - source_methods)
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
        source_methods + (all_methods - source_methods)
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
        return nil unless readable_source?(source_path)

        parse_result = AstCache.parse(source_path)
        constants = []
        find_constant_arrays(parse_result.value, constants)
        constants.empty? ? nil : constants
      rescue StandardError
        nil
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

      # Ruby does not always name the file holding the `class` keyword: a class
      # whose body raised leaves the constant a pending autoload, and Ruby
      # records Zeitwerk's cref.rb, which answers nothing the model declares.
      # A location inside the app is the model's own file; one outside it is
      # believed only when no model directory holds a file for the name, which
      # is what a gem's model looks like.
      def model_source_path(model)
        root = File.expand_path(app.root.to_s)
        located = Object.const_source_location(model.name)&.first
        return located if located && File.expand_path(located).start_with?("#{root}/")

        declared_source_path(model.name) || located
      rescue NameError, TypeError
        nil
      end

      # The file that declares the constant, from the walk that read the
      # files. A name does not round-trip to a path - an app inflection only
      # changes case, so `ActivityPub::Activity` lives in activitypub/ - and a
      # model in a pack or an engine is not under app/models at all.
      #
      # Built on the first miss and held for the run: a booted answer reaches
      # it only for a model whose constant Ruby cannot place inside the app.
      def declared_source_path(class_name)
        # Joined onto the app's own spelling of its root, not the realpath the
        # scan walked: the answer is relativized against that spelling, and on
        # a symlinked root (macOS /var) the two do not match.
        @declared_paths ||= static_candidates.each_with_object({}) do |(name, candidate), map|
          map[name] = candidate[:file] ? File.join(app.root.to_s, candidate[:file]) : candidate[:path]
        end
        @declared_paths[class_name.to_s]
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
        RailsAiContext.debug_fail(e, [], label: "generated_association_methods")
      end

      # The listener names an association with a Symbol and reflection with a
      # String, so the key is compared as text on both tiers.
      def excluded_association?(name)
        config.excluded_association_names.include?(name.to_s)
      end

      def reject_excluded_associations(associations)
        Array(associations).reject { |assoc| excluded_association?(assoc[:name]) }
                           .map { |assoc| booted_association_shape(assoc) }
      end

      # The booted tier lifts these options onto the record and spells every
      # name as a String, and each renderer reads them there; a static record
      # that leaves them nested under `options` reads as an association with
      # no `dependent:` and no `through:` at all.
      LIFTED_ASSOCIATION_OPTIONS = %i[through dependent class_name foreign_key polymorphic optional].freeze
      BOOLEAN_ASSOCIATION_OPTIONS = %i[polymorphic optional].freeze

      def booted_association_shape(assoc)
        return assoc unless assoc.is_a?(Hash)

        shaped = assoc.merge(assoc[:name] ? { name: assoc[:name].to_s } : {})
        options = assoc[:options]
        return shaped unless options.is_a?(Hash)

        LIFTED_ASSOCIATION_OPTIONS.each_with_object(shaped) do |key, acc|
          next unless options.key?(key) && !acc.key?(key)

          value = options[key]
          # `dependent: nil` is a declaration of nothing, and the booted tier
          # drops it; lifting it as "" renders `.dependent(:)`.
          next if value.nil?

          acc[key] = BOOLEAN_ASSOCIATION_OPTIONS.include?(key) ? value : value.to_s
        end
      end

      # A value that survives as itself: `in: %w[draft sent]` reached
      # `generate_test` as the String '["draft", "sent"]', which inspected
      # again gave shoulda's `in_array` one quoted String where it wants an
      # Array. Anything else is text, because a payload has to serialize.
      SANITIZED_SCALARS = [ Array, Numeric, TrueClass, FalseClass, NilClass, Symbol, String ].freeze

      def sanitize_options(options)
        options.reject { |_k, v| v.is_a?(Proc) || v.is_a?(Regexp) }
               .transform_values { |value| sanitize_option_value(value) }
      end

      def sanitize_option_value(value)
        return value.map { |element| sanitize_option_value(element) } if value.is_a?(Array)
        return value if SANITIZED_SCALARS.any? { |type| value.is_a?(type) }

        value.to_s
      end

      def static_model_details(path, class_name, file: relative_to_root(path), table_name: nil, inherited_from: [],
                               sti: nil)
        own = SourceIntrospector.call(path)
        data, unread, hidden = merge_concern_macros(own, class_name)
        data, unread, bases_unread, hidden = merge_inherited_macros(data, unread, hidden, inherited_from)
        own_methods = ActionResolver.own_methods(own[:methods], class_name)
        scope_names = Array(data[:scopes]).filter_map { |scope| scope[:name]&.to_s }.to_set
        static_instance_methods = own_methods.select { |m| m[:scope] == :instance && m[:visibility] == :public }.map { |m| m[:name].to_s }
        static_class_methods = own_methods.select { |m| m[:scope] == :class && m[:visibility] == :public }
                                          .map { |m| m[:name].to_s }.reject { |name| scope_names.include?(name) }
        details = {
          confidence: Confidence::STATIC,
          table_name: table_name || TableName.stem(path),
          associations: reject_excluded_associations(data[:associations]),
          # The booted tier's validations come from model.validators, which
          # never holds a `validate :method`; those are reported once, under
          # custom_validates.
          validations: Array(data[:validations]).reject { |v| v[:kind] == "custom" },
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
          concerns: static_concerns(data[:mixins]),
          concerns_hidden: (hidden.size if hidden.any?),
          concern_callbacks: concern_callbacks(data[:callbacks]),
          concerns_unread: (unread if unread.any?),
          bases_unread: (bases_unread if bases_unread.any?),
          macros: data[:macros],
          methods: own_methods,
          # The same two keys the booted tier carries, so a consumer reading
          # the model's method set gets the same answer in both tiers rather
          # than an empty one here.
          instance_methods: static_instance_methods.first(MAX_LISTED_METHODS),
          instance_method_count: static_instance_methods.size,
          class_methods: static_class_methods.first(MAX_LISTED_METHODS),
          class_method_count: static_class_methods.size,
          file: file,
          sti: sti
        }
        details.merge!(extract_macros_from_ast(data, path))
        details.merge!(extract_detailed_macros_from_ast(data))
        downgrade_records(details.compact)
      end

      # Both tiers collect all six. The booted tier reads five of them off the
      # source too - a concern's `validate :x` reaches custom_validates, its
      # enum options reach enum_options - and reflection overwrites the sixth,
      # associations, on that tier.
      MERGED_CONCERN_KEYS = %i[associations validations scopes enums callbacks macros].freeze

      # Reflection answers these whether or not the concern's file was read,
      # so on the booted tier an unread concern costs the other keys only.
      REFLECTED_CONCERN_KEYS = %i[associations validations enums].freeze

      # The mixin names are in the same walk and their files are on disk, so
      # the class's own declarations and its concerns' answer as one. Methods
      # and mixins stay the model's own: those are its interface, not the
      # sum of what it included.
      def merge_concern_macros(own, class_name)
        collected, unread, hidden = ConcernMacros.collect(
          app.root.to_s, own[:mixins] || [],
          keys: MERGED_CONCERN_KEYS, prefer: "model", within: class_name,
          cache: @source_cache
        )
        return [ own, unread, hidden ] if collected.empty?

        [ merge_inherited(own, collected), unread, hidden ]
      end

      # An STI child inherits its base's macros along with its table.
      # Reflection inherits three of the six keys - associations, validations
      # and enums - and the other three are read off the file, so both tiers
      # walk the chain the way they walk the concerns. Read nearest base
      # first, so the closer declaration wins over the further one.
      # A base the walk could not read is answered apart from the unread
      # concerns: it is a class, not a concern, and a child with no concerns
      # never reaches the line that names them.
      def merge_inherited_macros(data, unread, hidden, bases)
        bases_unread = []
        Array(bases).each do |name, path|
          own = sti_base_source(path)
          if own.nil?
            bases_unread |= [ name ]
            next
          end

          base, base_unread, base_hidden = merge_concern_macros(own, name)
          data = merge_inherited(data, base.slice(*MERGED_CONCERN_KEYS))
          # A base's concerns are the child's too: the child's record already
          # carries what they declared, and its callbacks credit them by name.
          data[:mixins] = Array(data[:mixins]) | Array(own[:mixins])
          unread |= base_unread
          hidden |= base_hidden
        end
        [ data, unread, bases_unread, hidden ]
      end

      # A base too big or unreadable costs its own declarations, not the
      # child's whole entry. The rescue still earns its place with the size
      # check in front of it: max_file_size can be configured above
      # AstCache::MAX_PARSE_SIZE, and the parse raises on its own limit.
      def sti_base_source(path)
        return nil unless readable_source?(path)

        @source_cache[path] ||= SourceIntrospector.call(path)
      rescue StandardError
        nil
      end

      # The size the whole introspector agrees a file is worth reading. Both
      # tiers ask this before the first walk, so a second walk over the same
      # file has to ask it too or the two disagree.
      def readable_source?(path)
        return false unless path && File.exist?(path)

        File.size(path) <= RailsAiContext.configuration.max_file_size
      rescue SystemCallError
        false
      end

      def merge_inherited(mine, inherited)
        merged = mine.merge(inherited) { |_key, ours, theirs| Array(ours) + Array(theirs) }
        merged[:associations] = dedup(merged[:associations]) { |a| [ a[:type], a[:name] ] }
        merged[:scopes] = dedup(merged[:scopes]) { |s| s[:name] }
        merged[:enums] = dedup(merged[:enums]) { |e| e[:name].to_s }
        # `encrypts :secret` on a base and again on the child is one macro, and
        # the consumers read it as a list of attributes. The key is the
        # declaration: the line it was read at differs between two files, and
        # the concern tag differs between two ways of reaching one file.
        merged[:macros] = dedup(merged[:macros]) { |m| m.except(:from_concern, :location) }
        # Rails keeps one entry for a symbol callback declared on a base and
        # again on the child, and two validators for a validation declared
        # twice, so these two are not deduped alike.
        merged[:callbacks] = dedup(merged[:callbacks]) { |c| [ c[:type], c[:method].to_s ] }
        # One source line read twice is still one declaration: a concern the
        # model and one of its bases both include is walked once per class, and
        # `included do` runs once. Two validations really written twice differ
        # by the line they are on and both stay.
        merged[:validations] = dedup(merged[:validations]) { |v| v }
        merged
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

      # A record cannot claim more than the tier that carries it: nothing in a
      # static entry is runtime-confirmed, whatever the listener read off the
      # file. A record the parser could not resolve keeps its own lower mark.
      def downgrade_records(details)
        details.transform_values do |value|
          next value unless value.is_a?(Array)

          value.map do |entry|
            entry.is_a?(Hash) && entry[:confidence] == Confidence::VERIFIED ? entry.merge(confidence: Confidence::STATIC) : entry
          end
        end
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
      # travels with the model instead. It goes into .ai-context.json, which
      # the app commits, so a gem path keeps the gem and drops the install
      # prefix.
      def relative_to_root(path)
        return nil if path.nil?

        PortablePath.relativize_marked(path, app.root.to_s)
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
        downgrade_records(details)
      end
    end
  end
end
