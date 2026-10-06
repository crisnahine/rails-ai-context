# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Extracts ActiveRecord model metadata using a hybrid approach:
    # - Rails reflection for runtime data (associations, validations, enums, table info)
    # - Prism AST for source-level declarations (scopes, callbacks, macros, methods)
    #
    # The AST layer replaces all regex/scan/match? source parsing with
    # Prism::Dispatcher-based single-pass extraction via SourceIntrospector.
    class ModelIntrospector < Base
      extend StaticTier
      static_tier :alternate_source

      attr_reader :config

      def initialize(app)
        super
        @config = RailsAiContext.configuration
        # One introspection per file per instance, so a concern or an STI base
        # shared by 100 models is walked once. Anything longer-lived would
        # outlast the files it read.
        @source_cache = {}
        @model_sources = {}
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

        tag_tenancy(result)
      end

      # Models the static scan finds, abstract bases left out. excluded_models is the app's
      # own filter, so it does not apply to another tree such as a loaded engine's.
      def model_count
        candidates = static_candidates
        candidates.count do |class_name, candidate|
          next false if candidate[:abstract] || candidate[:error]

          model_class?(class_name, candidates)
        end
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
        models = candidates.each_with_object({}) do |(class_name, candidate), result|
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
                                                    primary_key: resolve_primary_key(class_name, candidates),
                                                    inherited_from: declaring_bases(class_name, candidates),
                                                    sti: static_sti_info(class_name, sti_parents),
                                                    parent_model: sti_parents[class_name])
        rescue => e
          # What the booted tier does with a model that raises: the entry says
          # so and the rest of the section still answers. It keeps the two
          # facts the unreadable branch keeps, because a consumer with no file
          # derives app/models/<name>.rb, which is a path a pack model does
          # not have.
          result[class_name] = { error: e.message, file: candidate[:file], table_name: table }.compact
        end
        tag_tenancy(models)
      end

      private

      # Apartment keeps an excluded model, and an STI subclass sharing its table, in the
      # shared schema; every other ActiveRecord model has a table in each tenant's schema.
      def tag_tenancy(models)
        config = ApartmentConfig.read(app.root) or return models
        excluded = config[:excluded_models]
        models.each do |name, data|
          next if data[:error] || data[:mongoid]

          scope = if excluded.nil? then "unknown"
          elsif apartment_shared?(name, models, excluded) then "shared"
          else "per_tenant"
          end
          data[:tenancy] = { gem: "apartment", scope: scope, declared_in: config[:file], excluded_models: config[:excluded_models_source] }.compact
        end
      end

      def apartment_shared?(name, models, excluded, seen = [])
        return true if excluded.include?(name)
        return false if seen.include?(name)

        parent = models.dig(name, :sti, :sti_parent)
        parent ? apartment_shared?(parent, models, excluded, seen + [ name ]) : false
      end

      # The same shape the booted tier reports under :sti, off the chain the
      # static tier already resolves to share the base's table. The caller
      # drops it when the schema shows that table has no type column.
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

      # Rails runs no STI on a table without the type column; a table the dump does not hold is not known to lack it.
      def lacks_column?(table, column)
        reader = SchemaReader.for(app.root)
        reader.tables.key?(table) && column != RailsAiContext::Confidence::INFERRED && !reader.column?(table, column)
      end

      # Rails' default column, the literal a class sets, or nil where `inheritance_column = nil` turns STI off.
      def static_type_column(literals)
        return "type" unless literals&.key?("inheritance_column")

        literals["inheritance_column"].presence
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
          # Other roots hold generators and gem subclasses too; static lists one only as a model.
          next if @outside_model_dirs&.include?(class_name) && !static_model?(class_name, candidates)

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
        SourceScan.model_paths(app.root).each_with_object({}) do |record, found|
          begin
            source = model_source(record.path) if File.size(record.path) <= RailsAiContext.configuration.max_file_size
            if source.nil?
              found[record.path_name] ||= unread_candidate(record) unless skip_unread?(record)
              next
            end

            next if mixin_path?(record.path_name.underscore, source)

            declarations = DeclaredConstant.declarations(source)
            declaration = DeclaredConstant.declaration_for(declarations, record.path_name)
            class_name = declaration&.name || record.path_name
            # Two files can declare one class (an app reopening a model to add methods);
            # the one that names a superclass defines the model.
            previous = found[class_name]
            next if previous && (previous[:superclass] || declaration&.superclass.nil?)

            # A module file declares no class and is kept for the prefix and
            # the suffix alone: they belong to the namespace, not to any one
            # model.
            found[class_name] = {
              path: record.path,
              file: record.file,
              superclass: declaration&.superclass,
              superclass_nesting: declaration&.nesting,
              abstract: abstract_class?(source)
            }.merge(TableName.declarations(source, class_name, app.root))
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

      def static_model?(class_name, candidates)
        candidates.key?(class_name) && !candidates.dig(class_name, :abstract) && model_class?(class_name, candidates)
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
        nesting = candidates.dig(from, :superclass_nesting)
        SuperclassChain.resolve_in_scope(from, name, nesting: nesting) { |qualified| qualified if candidates.key?(qualified) }
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
          contained_prefix(class_name, candidates, seen),
          TableName.stem(candidate[:path], pluralize_tables?(class_name, candidates)),
          namespace_affix(class_name, candidates, :table_name_suffix) ].join
      end

      # A key the class does not assign is read through a new connection, which an
      # unreachable host can hold for a full connect timeout per model; unconnected, read the source.
      def model_primary_key(model)
        return model.primary_key if model.connected?

        base = model.respond_to?(:base_class) ? model.base_class : model
        path = model_source_path(base)
        path && TableName.declarations(model_source(path), base.name, app.root)[:primary_key]
      rescue StandardError => e
        RailsAiContext.debug_fail(e, nil, label: "model_primary_key")
      end

      # Rails reads an STI child's key off its base class; an abstract base's assignment reaches no model.
      def resolve_primary_key(class_name, candidates, seen = [])
        own = candidates.dig(class_name, :primary_key)
        return own if own

        parent = sti_parent(class_name, candidates, seen)
        parent && resolve_primary_key(parent, candidates, seen + [ class_name ])
      end

      # A class attribute: the class's own assignment, else its superclass chain's, else the app's.
      def pluralize_tables?(class_name, candidates, seen = [])
        own = candidates.dig(class_name, :pluralize_table_names)
        return own unless own.nil?

        parent = candidates.dig(class_name, :superclass)
        resolved = parent && !seen.include?(class_name) && resolve_superclass(parent, class_name, candidates)
        return pluralize_tables?(resolved, candidates, seen + [ class_name ]) if resolved && candidates.key?(resolved)

        TableName.app_affixes(app.root)[:pluralize_table_names] != false
      end

      # compute_table_name (7.0 and 8.1): a class nested in a concrete model
      # takes that model's singular table as a prefix (Project::Phase, project_phases).
      def contained_prefix(class_name, candidates, seen)
        parent = class_name.split("::")[0..-2].join("::")
        return "" if parent.empty? || seen.include?(parent) || candidates.dig(parent, :abstract)
        return "" unless model_class?(parent, candidates)

        table = resolve_table_name(parent, candidates, seen + [ class_name ])
        return "" if table.to_s.empty?

        "#{pluralize_tables?(parent, candidates) ? table.singularize : table}_"
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

      # Rails' full_table_name_prefix: the innermost module parent that answers,
      # else the class's own attribute, which config.active_record sets.
      def namespace_affix(class_name, candidates, key)
        scope = class_name.split("::")[0..-2]
        while scope.any?
          namespace = scope.join("::")
          # A module's own declaration answers before the one `isolate_namespace` would give it.
          declared = candidates.dig(namespace, key) ||
                     (key == :table_name_prefix ? isolated_prefixes[namespace] : nil)
          return declared if declared

          scope.pop
        end
        candidates.dig(class_name, key) || TableName.app_affixes(app.root)[key] || ""
      end

      def isolated_prefixes
        @isolated_prefixes ||= TableName.namespace_prefixes(app.root)
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

      # A class whose file is inside an installed gem (PaperTrail::Version) is
      # the gem's, not the app's; a path gem kept in the repo is the app's, and
      # so is a gem the app itself sits inside (an engine's dummy app).
      def gem_defined?(model)
        # A class whose body raised is still an autoload, and its location is
        # the loader's own file, which says nothing about who defines it.
        *scope, last = model.name.split("::")
        return false if (scope.empty? ? Object : scope.join("::").safe_constantize)&.autoload?(last)

        location = Object.const_source_location(model.name)&.first
        return false unless location

        PortablePath.gem_file?(location, app.root)
      rescue NameError, ArgumentError, TypeError
        false
      end

      def model_dir_file?(path)
        PathResolver.model_dirs(app.root).any? { |dir| SafePath.contained?(path, PathResolver.root_key(dir)) }
      end

      def discover_models
        return [] unless defined?(ActiveRecord::Base)

        models = ActiveRecord::Base.descendants.reject do |model|
          model.abstract_class? ||
            model.name.nil? ||
            gem_defined?(model) ||
            DeclaredConstant.renamed?(model) ||
            config.excluded_models.include?(model.name)
        end

        known = models.map(&:name).to_set
        @outside_model_dirs = Set.new
        # Concerns stay in: a nested concerns directory is a namespace, so a
        # class declared under one is a model and constantize sorts the mixins
        # out. A top-level `app/models/concerns` is an autoload root instead,
        # so its files declare no `Concerns::` prefix and that path name never
        # constantizes.
        SourceScan.model_paths(app.root, base_model: model_base_check).each do |record|
          next if record.path_name.start_with?("Concerns::")
          next if known.include?(record.path_name)
          next if config.excluded_models.include?(record.path_name)

          # The path does not name the class: an app inflection only changes
          # case, so activitypub/activity.rb camelizes to a constant the app
          # does not have and the file was listed as a model that will not
          # load. A root pushed under a namespace declares a prefix the path
          # lacks. Read only where the camelized name is not already loaded, so
          # a booted run does not parse every model file to learn nothing.
          class_name = DeclaredConstant.named(model_source(record.path).to_s, record.path_name)
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
            @outside_model_dirs << class_name unless model_dir_file?(record.path)
          end
        end

        models.uniq.sort_by(&:name)
      end

      def extract_model_details(model)
        # AST-based source introspection (replaces all regex parsing)
        own_source = own_body(introspect_source(model), model.name)
        # Reflection covers associations, validations and enums, but scopes,
        # macros and custom validates are read off the file - so the concerns
        # and the superclasses are merged here too, or the static tier
        # out-answers this one.
        bases = booted_declaring_bases(model)
        calls = singleton_lookup([ [ model.name, model_source_path(model) ], *bases ])
        source_data, unread, bases_unread, hidden =
          merge_class_and_bases(own_source, model.name, calls, bases, file: model_source_path(model),
                                commits_in_order: booted_commits_in_order)

        class_methods = extract_class_methods_from_ast(model, source_data)
        instance_methods = extract_instance_methods_from_ast(model, source_data)
        # The model's own public instance methods, uncapped: a display cap
        # decides what a page prints, never whether a method exists, and
        # reflection's own list is inflated by an attribute method per column
        # as soon as anything instantiates the model.
        source_instance_methods = own_source_methods(model, source_data)

        details = {
          table_name:       model.table_name,
          primary_key:      model_primary_key(model),
          file:             relative_to_root(model_source_path(model)),
          # Reflection-based (runtime, most accurate for these)
          associations:     extract_associations(model, source_data),
          # Reflection has no text for a Proc condition and names `validates_with` by kind only,
          # so the list is read off the source; an unreadable file falls back to reflection.
          validations:      booted_validations(model, source_data),
          enums:            extract_enums(model),
          # Rails' event chains carry the framework's own registrations and
          # hold no block callbacks, so both tiers read the model's source.
          callbacks:        group_callbacks_by_type(source_data[:callbacks]),
          callback_conditions: callback_conditions(source_data[:callbacks]),
          concerns:         booted_concerns(model, source_data[:mixins]),
          concern_sources:  concern_sources(booted_concerns(model, source_data[:mixins]), source_data[:mixins], booted: true),
          concerns_hidden:  (hidden.size if hidden.any?),
          concern_callbacks: concern_callbacks(source_data[:callbacks]),
          concerns_unread:  (unread if unread.any?),
          bases_unread:     (bases_unread if bases_unread.any?),
          conditional_declarations: declarations(source_data[:conditional]),
          foreign_declarations: declarations(source_data[:foreign]),
          # AST-based (replaces regex source parsing)
          custom_validates: extract_custom_validates_from_ast(source_data),
          custom_validate_conditions: custom_validate_conditions(source_data),
          custom_validate_blocks: custom_validate_blocks(source_data),
          scopes:           extract_scopes_from_ast(source_data),
          default_scopes:   default_scopes(source_data),
          class_methods:    class_methods.first(PAYLOAD_METHOD_CAP),
          class_method_count: class_methods.size,
          instance_methods: instance_methods.first(PAYLOAD_METHOD_CAP),
          instance_method_count: instance_methods.size,
          source_instance_methods: source_instance_methods
        }

        sti_info = extract_sti_info(model)
        details[:sti] = sti_info if sti_info

        parent = model.superclass
        details[:parent_model] = parent.name if parent < ActiveRecord::Base && !parent.abstract_class?

        # AST-based enum options (replaces regex)
        enum_options = extract_enum_options_from_ast(source_data)
        details[:enum_options] = enum_options if enum_options.any?

        # AST-based macro extractions (replaces regex)
        macros = extract_macros_from_ast(source_data, model_source_path(model))
        details.merge!(macros.except(:setting_literals))

        # AST-based detailed macros (replaces regex)
        detailed = extract_detailed_macros_from_ast(source_data)
        details.merge!(detailed)
        details[:ignored_columns] = model.ignored_columns.map(&:to_s).presence

        details.compact
      end

      # Run SourceIntrospector on the model's source file.
      # Returns the full AST introspection result or empty hash.
      def introspect_source(model)
        return empty_source_data unless source_readable?(model)

        source_walk(model_source_path(model))
      rescue => e
        RailsAiContext.debug_fail(e, empty_source_data, label: "AST introspection for #{model.name}")
      end

      def source_readable?(model)
        path = model_source_path(model)
        !!(path && File.exist?(path) && File.size(path) <= RailsAiContext.configuration.max_file_size)
      end

      # `validate :method` is not a validator; both tiers report it once,
      # under custom_validates.
      def declared_validations(source_data)
        Array(source_data[:validations]).reject { |v| v[:kind] == "custom" }
      end

      # The source list keeps each rule's text (conditions, the validates_with
      # class); reflection adds what no line the reader parses declares (a gem
      # module's, one built in a loop), after the declared ones, where the
      # static tier lists the ones a known macro adds.
      def booted_validations(model, source_data)
        return extract_validations(model) unless source_readable?(model)

        declared, added = declared_validations(source_data).partition { |v| v[:added_by].nil? }
        implicit = booted_required_belongs_to(model)
        belongs_to = model.reflect_on_all_associations(:belongs_to).map { |a| a.name.to_s }
        undeclared = model.validators.reject do |validator|
          attributes = validator.respond_to?(:attributes) ? validator.attributes.map(&:to_s) : []
          (required_presence?(validator) && attributes.one? && belongs_to.include?(attributes.first)) ||
            declared.any? { |v| declares?(v, validator, attributes) }
        end
        declared = declared.flat_map { |v| with_computed_attributes(v, undeclared, added) }
        implicit_presence(implicit) + declared + reflected_validations(undeclared, added)
      end

      # `validates field, length: ...` in a loop: reflection knows which
      # attributes it ran for, so those stand in for the one computed line.
      def with_computed_attributes(declaration, undeclared, added = [])
        return [ declaration ] unless declaration[:computed_attributes] && declaration[:attributes].empty?

        # A validator a known macro adds (has_secure_password, devise) keeps its own label.
        ran = undeclared.select do |validator|
          record = validation_record(validator)
          validator.kind.to_s == declaration[:kind] &&
            added.none? { |v| v[:kind] == record[:kind] && v[:attributes] == record[:attributes] }
        end
        return [ declaration ] if ran.empty?

        undeclared.replace(undeclared - ran)
        ran.map { |validator| validation_record(validator).merge(computed_attributes: declaration[:computed_attributes]) }
      end

      # A validator is the declaration's when kind and attribute agree, when
      # validates_with names its class, or when a gem's own macro
      # (`validates_date`) covers the attribute under its own name.
      def declares?(declaration, validator, attributes)
        return declaration[:validator].to_s == validator.class.name if declaration[:kind] == "validates_with"

        overlap = (Array(declaration[:attributes]) & attributes).any?
        overlap && (declaration[:kind] == validator.kind.to_s || declaration[:kind].start_with?("validates_"))
      end

      def reflected_validations(validators, added)
        validators.map do |validator|
          record = validation_record(validator)
          macro = added.find { |v| v[:kind] == record[:kind] && v[:attributes] == record[:attributes] }
          macro ? record.merge(added_by: macro[:added_by]) : record.merge(reflection_only: true)
        end
      end

      # `paths` is the model's file, then its bases' nearest first.
      def static_validations(data, paths = [])
        declared, added = declared_validations(data).partition { |v| v[:added_by].nil? }
        default = class_required_default(paths)
        default = belongs_to_required_by_default? if default.nil?
        implicit_presence(static_required_belongs_to(reject_excluded_associations(data[:associations]), default)) +
          declared + for_rails_version(added)
      end

      # `self.belongs_to_required_by_default = false` in a class body wins over
      # the app's default, and a subclass inherits its parent's (27 OFN models).
      def class_required_default(paths)
        paths.each do |path|
          source = path && model_source(path) or next
          next unless source.include?("belongs_to_required_by_default")

          AstWalk.each(AstCache.parse_string(source).value) do |node|
            next unless node.is_a?(Prism::CallNode) && node.receiver.is_a?(Prism::SelfNode)

            return setting_value(node) if node.name == :belongs_to_required_by_default=
          end
        end
        nil
      end

      # A macro's validators as the app's locked Rails registers them; with no
      # version locked, the current ones, and the label says so.
      def for_rails_version(added)
        version = rails_version
        added.filter_map do |v|
          before = v[:before_rails]
          next v unless before || (version.nil? && v[:added_by] == "has_secure_password")
          next nil if before && (version.nil? || Gem::Version.new(version) >= Gem::Version.new(before))

          v = v.except(:before_rails)
          version ? v : v.merge(added_by: "#{v[:added_by]}, assuming Rails 7.1+ as Gemfile.lock names no Rails version")
        end
      end

      def rails_version
        return @rails_version if defined?(@rails_version)

        lock = GemLock.for(app.root)
        @rails_version = lock.version("rails") || lock.version("railties")
      end

      # Rails adds `validates_presence_of name, message: :required` for a
      # required belongs_to; no line of the model declares it.
      # A name alone is certain; [name, condition] holds only when the
      # expression the static tier cannot evaluate says so.
      def implicit_presence(names)
        names.map do |name, condition|
          { kind: "presence", attributes: [ name ], options: {}, implicit: true, implicit_if: condition }.compact
        end
      end

      # Reflection already applied optional:, required: and the app's default.
      def booted_required_belongs_to(model)
        required = model.validators.select { |v| required_presence?(v) }.flat_map { |v| v.attributes.map(&:to_s) }
        model.reflect_on_all_associations(:belongs_to).map { |a| a.name.to_s }
             .reject { |name| excluded_association?(name) }.select { |name| required.include?(name) }
      end

      def required_presence?(validator)
        validator.kind == :presence && validator.options[:message] == :required
      end

      # Rails' rule: a required: key sets optional: to its negation, then a nil
      # optional: means the app's default. An unevaluable option makes it conditional.
      def static_required_belongs_to(associations, default = belongs_to_required_by_default?)
        Array(associations).select { |a| a.is_a?(Hash) && a[:type].to_s == "belongs_to" }.filter_map do |a|
          name = a[:name].to_s
          options = a[:options] || {}
          optional_value = a.key?(:optional) ? a[:optional] : options[:optional]
          if options.key?(:required)
            required = literal_boolean(options[:required])
            required.nil? ? [ name, "required: #{options[:required]} is true" ] : (name if required)
          elsif !optional_value.nil?
            optional = literal_boolean(optional_value)
            optional.nil? ? [ name, "optional: #{optional_value} is false" ] : (name unless optional)
          elsif default.is_a?(String) then [ name, default ]
          elsif default then name
          end
        end
      end

      def literal_boolean(value)
        { true => true, false => false, nil => false, "true" => true, "false" => false }[value]
      end

      # Without a `belongs_to_required_by_default =` of its own, Rails turns it
      # on from `load_defaults 5.0`. True, false, or the condition it holds under.
      def belongs_to_required_by_default?
        setting = framework_setting(:belongs_to_required_by_default=, since: 5.0)
        setting.assigned ? setting.value : setting.version.to_f >= 5.0
      end

      # `value` is the deciding assignment's setting_value when `assigned`;
      # else `load_defaults`' `version` decides.
      FrameworkSetting = Struct.new(:assigned, :value, :version, :read, keyword_init: true)

      # Application.rb then the initializers, as Rails runs them; a `load_defaults`
      # of version `since` or later assigns the setting too, and the last line wins.
      def framework_setting(setter, since:)
        @framework_settings ||= {}
        @framework_settings[setter] ||= begin
          root = app.root.to_s
          application = File.join(root, "config", "application.rb")
          setting = FrameworkSetting.new(assigned: false, read: false)
          [ application, *PathResolver.initializer_paths(root) ].each do |path|
            source = SafeFile.read(path) or next
            setting.read ||= path == application
            AstWalk.each(AstCache.parse_string(source).value) do |node|
              next unless node.is_a?(Prism::CallNode)

              if node.name == setter && node.receiver
                setting.assigned = true
                setting.value = setting_value(node)
              elsif node.name == :load_defaults && path == application && node.receiver&.slice.to_s == "config"
                setting.version = defaults_version(node.arguments&.arguments&.first)
                setting.assigned = false if setting.version.to_f >= since
              end
            end
          end
          setting
        end
      end

      # A literal true, false or nil (false, as Rails tests for truth) as itself;
      # any other value reads as the condition "<setting> = <expression> is true".
      def setting_value(node)
        value = node.arguments&.arguments&.first
        literal = { Prism::TrueNode => true, Prism::FalseNode => false, Prism::NilNode => false }[value.class]
        return literal unless literal.nil? && value

        "#{node.name.to_s.delete_suffix('=')} = #{value.slice} is true"
      end

      # A literal version as written; anything else (`Rails::VERSION::STRING.to_f`) is the
      # running Rails, Float::INFINITY: on for belongs_to, unknown for the commit order.
      def defaults_version(arg)
        case arg
        when Prism::FloatNode, Prism::IntegerNode then arg.value.to_f
        when Prism::StringNode then arg.unescaped.to_f
        when nil then nil
        else Float::INFINITY
        end
      end

      # The model's own mixins: its ancestor modules less every module in
      # ActiveRecord::Base's chain, which is what a gem (or an initializer)
      # puts into all models. A module a gem macro includes into this model
      # alone (`devise :lockable`) stays.
      def booted_concerns(model, mixins = [])
        own = (model.ancestors - every_model_modules - base_gem_modules(model, mixins)).reject { |mod| mod.is_a?(Class) }.filter_map(&:name).reverse
        ConcernMembership.payload(own)
      end

      # A gem can mix a module into the app's abstract base (Kaminari's
      # inherited hook): every model then has it and no file of the app names
      # it. A module the source includes, or one the app defines, stays.
      def base_gem_modules(model, mixins)
        written = ConcernMembership.from_mixins(mixins)
        gem_bases(model).flat_map { |base| base.ancestors - every_model_modules }.uniq.select do |mod|
          !mod.is_a?(Class) && mod.name && !written.include?(mod.name) && !ConcernPaths.find_file(app.root.to_s, mod.name)
        end
      end

      def abstract_bases(model)
        model.ancestors.select { |klass| klass.is_a?(Class) && klass < ActiveRecord::Base && klass != model && klass.abstract_class? }
      end

      # The bases a gem's inherited hook reaches as it reaches the model. Kaminari's
      # reaches every direct ActiveRecord::Base child, so a model that is one is
      # measured against the app's abstract bases that are one too.
      def gem_bases(model)
        bases = abstract_bases(model)
        return bases unless model.superclass == ActiveRecord::Base

        bases | ActiveRecord::Base.subclasses.select { |klass| klass.name && klass.abstract_class? }
      end

      def every_model_modules
        @every_model_modules ||= ActiveRecord::Base.ancestors
      end

      # The source's mixins, plus the modules `devise :a, :b` includes by
      # Devise's own naming rule, so both tiers agree for Devise.
      def static_concerns(mixins, path)
        ConcernMembership.from_mixins(mixins) | ConcernMembership.payload(devise_modules(path))
      end

      def devise_modules(path)
        source = path && model_source(path)
        return [] unless source&.include?("devise")

        walked = SourceIntrospector.walk_source(source, { devise: -> { Listeners::GenericMacroListener.new(:devise) } })
        names = Array(walked[:devise]).flat_map { |hit| Array(hit[:args]) }.map { |arg| "Devise::Models::#{arg.to_s.classify}" }
        names.any? ? [ "Devise::Models::Authenticatable", *names ].uniq : []
      end

      # Where a concern no `include` in the source names comes from: Devise's
      # macro, or, booted, a macro reflection alone can see.
      def concern_sources(concerns, mixins, booted:)
        written = ConcernMembership.from_mixins(mixins)
        sources = (concerns - written).each_with_object({}) do |name, found|
          if name.start_with?("Devise::Models::") then found[name] = "devise"
          elsif booted && !ConcernPaths.find_file(app.root.to_s, name) then found[name] = "a gem macro (booted only)"
          end
        end
        sources.presence
      end

      def empty_source_data
        { associations: [], validations: [], scopes: [], enums: [], callbacks: [], macros: [], methods: [] }
      end

      # ── Reflection-based extraction (unchanged) ─────────────────────

      def extract_associations(model, source_data = empty_source_data)
        declared = Array(source_data[:associations]).group_by { |a| [ a[:type].to_s, a[:name].to_s ] }
        # The reject stays ahead of the map: class_name/foreign_key on an
        # excluded reflection with a broken :through raises, and `call`'s
        # per-model rescue would replace the whole model with one error line.
        model.reflect_on_all_associations.reject { |assoc| excluded_association?(assoc.name) }.map do |assoc|
          with_declared_options(association_detail(assoc), declared[[ assoc.macro.to_s, assoc.name.to_s ]]&.first, model)
        end
      end

      # Only what the source declares, so both tiers print one spelling; a gem
      # macro's generated association carries Rails' options, not the app's.
      def with_declared_options(detail, source, model = nil)
        options = declared_association_options(detail[:type], source&.dig(:options))
        extensions = source&.dig(:extension_methods)
        delegated = source&.dig(:delegated_types)
        unread = source&.dig(:delegated_types_source)
        # delegated_type defines `<role>_types`, which answers a list the source names only as an expression.
        if unread && model.respond_to?(reader = :"#{detail[:name]}_types")
          delegated = Array(model.public_send(reader)).map(&:to_s).presence
          unread = nil if delegated
        end
        detail.merge({ declared_options: options, extension_methods: extensions, delegated_types: delegated,
                       delegated_types_source: unread }.compact)
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
          # A leading `::` stays: it means top level to the class resolver.
          class_name: assoc.class_name.to_s,
          # Rails 7.1+ answers an Array for a composite key.
          foreign_key: assoc.foreign_key.is_a?(Array) ? assoc.foreign_key.map(&:to_s) : assoc.foreign_key.to_s
        }
        detail[:through]    = assoc.options[:through].to_s if assoc.options[:through]
        detail[:source_type] = assoc.options[:source_type].to_s if assoc.options[:source_type]
        # Only when declared, as the static tier lifts them: reflection answers
        # a default for both, and the static tier cannot see one.
        detail[:join_table] = assoc.join_table.to_s if assoc.options.key?(:join_table)
        if assoc.options.key?(:association_foreign_key)
          detail[:association_foreign_key] = assoc.association_foreign_key.to_s
        end
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
        implicit = booted_required_belongs_to(model)
        model.validators.map do |validator|
          record = validation_record(validator)
          attributes = record[:attributes]
          next implicit_presence(attributes).first if required_presence?(validator) && attributes.one? && implicit.include?(attributes.first)

          record
        end
      end

      def validation_record(validator)
        # `validates_with` registers a bare ActiveModel::Validator, which
        # has no #attributes - only EachValidator does. Calling it blind
        # replaced the whole model's answer with one error line.
        attributes = validator.respond_to?(:attributes) ? Array(validator.attributes).map(&:to_s) : []
        { kind: validator.kind.to_s, attributes: attributes, options: sanitize_options(validator.options) }
      end

      def extract_enums(model)
        return {} unless model.respond_to?(:defined_enums)
        model.defined_enums.transform_values { |mapping| mapping.dup }
      end

      def extract_sti_info(model)
        type_column = model.inheritance_column.to_s
        has_type_column = if model.connected? && model.table_exists?
          model.columns_hash.key?(type_column)
        else
          SchemaReader.for(app.root).column?(model.table_name, type_column)
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
          sti_children: children.empty? ? nil : children,
          type_column: type_column
        }.compact
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "extract_sti_info")
      end

      # ── AST-based extraction (replaces all regex parsing) ──────────

      def extract_scopes_from_ast(source_data)
        source_data[:scopes].reject { |s| s[:default] }.map do |s|
          {
            name: s[:name],
            body: s[:body],
            required_params: s[:required_params] || [],
            confidence: s[:confidence]
          }.compact
        end
      end

      # Base first, as Rails stacks them; each one filters every query.
      def default_scopes(source_data)
        found = Array(source_data[:scopes]).select { |s| s[:default] }.map { |s| s.slice(:body, :all_queries, :confidence) }
        found.presence
      end

      def extract_custom_validates_from_ast(source_data)
        source_data[:validations]
          .select { |v| v[:kind] == "custom" }
          .flat_map { |v| v[:attributes] }
      end

      # A validate block is listed by what it runs; Rails registers it next to any methods named.
      def custom_validate_blocks(source_data)
        found = Array(source_data[:validations]).select { |v| v[:kind] == "custom" && v[:block] }.map do |v|
          { body: v[:block], conditions: (v[:options] || {}).slice(*CONDITION_KEYS, :on).presence }.compact
        end
        found.presence
      end

      # `validate :check, on: :create` runs only then; the method name alone
      # reads as a rule that always holds.
      def custom_validate_conditions(source_data)
        found = Array(source_data[:validations]).select { |v| v[:kind] == "custom" }.each_with_object({}) do |v, hash|
          conditions = (v[:options] || {}).slice(*CONDITION_KEYS, :on)
          v[:attributes].each { |name| hash[name.to_s] = conditions } if conditions.any?
        end
        found.presence
      end

      # The options that decide the value a new record holds and the names of
      # the methods the enum defines.
      def extract_enum_options_from_ast(source_data)
        Array(source_data[:enums]).each_with_object({}) do |enum, opts|
          options = enum[:options] || {}
          entry = %i[prefix suffix default].to_h { |key| [ key, options.fetch(key) { options[:"_#{key}"] } ] }
          entry.reject! { |_, value| value.nil? || value == false }
          opts[enum[:name].to_s] = entry if entry.any?
        end
      end

      CONDITION_KEYS = %i[if unless].freeze

      # One conditions entry per callback, in step with the name list: one method can sit under
      # two types with different conditions.
      def callback_conditions(callbacks)
        Array(callbacks).each_with_object({}) do |cb, hash|
          next unless cb.is_a?(Hash) && cb[:type]

          options = cb[:options] || {}
          conditions = options.select { |key, _| CONDITION_KEYS.include?(key) }
          conditions = { on: options[:on] }.merge(conditions) if options.key?(:on) && !Listeners::CallbacksListener.names_event?(cb[:type])
          (hash[cb[:type].to_s] ||= []) << (conditions.empty? ? nil : conditions)
        end.reject { |_, list| list.none? }
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
      PAYLOAD_METHOD_CAP = 30

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
        # The abstract bases' class methods reach every model, the static tier reads none of
        # them, and a gem's (Kaminari's `page`) would otherwise be listed on each model.
        base_methods = gem_bases(model).flat_map(&:methods)
        all_methods = (model.methods - ActiveRecord::Base.methods - Object.methods - base_methods)
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

      # The model's own public instance methods, from its source alone.
      def own_source_methods(model, source_data)
        ActionResolver.own_methods(source_data[:methods], model.name)
          .select { |m| m[:scope] == :instance && m[:visibility] == :public }
          .map { |m| m[:name].to_s }
      end

      def extract_instance_methods_from_ast(model, source_data)
        generated = generated_association_methods(model)

        # Source-defined instance methods (AST), the model's own.
        source_methods = own_source_methods(model, source_data)

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
        has_secure_token: :has_secure_token,
        attr_readonly: :attr_readonly,
        query_constraints: :query_constraints
      }.freeze

      STORE_MACROS = %i[store store_accessor].to_set.freeze

      BROADCAST_MACROS = %i[broadcasts broadcasts_to broadcasts_refreshes_to].to_set.freeze

      def extract_macros_from_ast(source_data, source_path = nil)
        macros = {}
        source_data[:macros].each do |m|
          macro = m[:macro]

          if macro == :has_secure_password
            macros[:has_secure_password] = true
            (macros[:secure_passwords] ||= []) << { attribute: m[:attribute], options: m[:written] || {} }
          elsif (key = ATTRIBUTE_MACRO_MAP[macro])
            (macros[key] ||= []) << m[:attribute]
            (macros[:serialize_options] ||= {})[m[:attribute]] = m[:written] if macro == :serialize && m[:written]&.any?
          elsif STORE_MACROS.include?(macro)
            add_store_accessors(macros, m)
          elsif macro == :accepts_nested_attributes_for
            (macros[:nested_attributes] ||= []) << { names: m[:names], options: m[:options] }.compact
          elsif macro == :ignored_columns
            macros[:ignored_columns] = apply_ignored_columns(macros[:ignored_columns] || [], m)
          elsif macro == :delegate
            (macros[:delegations] ||= []) << delegation_entry(m)
          elsif macro == :delegate_missing_to
            macros[:delegate_missing_to] = m[:to]
          elsif macro == :attribute
            (macros[:attributes] ||= []) << { name: m[:attribute], type: m[:type], default: m.dig(:options, :default) }.compact
          elsif macro == :alias_attribute
            (macros[:alias_attributes] ||= []) << { name: m[:attribute], target: m[:target] }
          elsif macro == :model_setting
            # Bases arrive first, so the class's own assignment wins.
            (macros[:model_settings] ||= {})[m[:setting]] = m[:value]
            (macros[:setting_literals] ||= {})[m[:setting]] = m[:literal]
          elsif macro == :connects_to
            macros[:database] = { connects_to: m[:text], condition: m[:condition], declared_in: m[:declared_in], writing: m[:writing] }.compact
          elsif macro == :gem_macro
            (macros[:gem_macros] ||= []) << m.slice(:text, :adds)
          elsif macro == :aasm
            (macros[:state_machines] ||= []) << m.slice(:column, :initial, :states, :events)
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

      # Declarations arrive bases first, so `=` replaces what a base set and
      # `+=` adds to it; a list the source computes cannot be read.
      def apply_ignored_columns(current, macro)
        return [ RailsAiContext::Confidence::INFERRED ] if macro[:columns].nil? || current.include?(RailsAiContext::Confidence::INFERRED)

        case macro[:op]
        when :assign then macro[:columns].uniq
        when :add then (current + macro[:columns]).uniq
        else current - macro[:columns]
        end
      end

      # Rails names a store accessor "#{prefix}_#{key}_#{suffix}", where true
      # stands for the column name (ActiveRecord::Store.store_accessor).
      def add_store_accessors(macros, macro)
        column = macro[:attribute]
        (macros[:store] ||= []) << column unless macros[:store]&.include?(column)
        keys = macro[:keys] || []
        return if keys.empty?

        options = macro[:options] || {}
        accessors = (macros[:store_accessors] ||= {})[column] ||= []
        affixes = options.values_at(:prefix, :suffix)
        if affixes.include?(RailsAiContext::Confidence::INFERRED)
          accessors << RailsAiContext::Confidence::INFERRED unless accessors.include?(RailsAiContext::Confidence::INFERRED)
          return
        end

        prefix, suffix = affixes.map { |affix| affix == true ? column : (affix.is_a?(Symbol) || affix.is_a?(String) ? affix : nil) }
        keys.each do |key|
          name = [ prefix, key, suffix ].compact.join("_")
          accessors << name unless accessors.include?(name)
        end
      end

      # ActiveSupport names a prefixed delegate "#{prefix == true ? to : prefix}_#{method}".
      def delegation_entry(macro)
        options = macro[:options] || {}
        entry = { methods: macro[:methods], to: macro[:to] }
        entry[:private] = true if options[:private] == true
        prefix = options[:prefix]
        case prefix
        when true, Symbol, String
          if prefix == RailsAiContext::Confidence::INFERRED
            entry[:prefix_computed] = true
          else
            head = prefix == true ? macro[:to] : prefix
            entry[:defines] = macro[:methods].map { |name| "#{head}_#{name}" } if head
          end
        end
        entry
      end

      # Extract constant definitions from source via AST.
      # Finds ConstantWriteNode where the value is an ArrayNode
      # (covers %w[], %i[], and literal array forms).
      def extract_constants_from_source(source_path)
        return nil unless readable_source?(source_path)

        parse_result = AstCache.parse_string(model_source(source_path).to_s)
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
            value_node = unwrap_frozen(node.value)

            if value_node.is_a?(Prism::ArrayNode)
              values = value_node.elements.filter_map { |el|
                case el
                when Prism::StringNode then el.unescaped
                when Prism::SymbolNode then el.unescaped
                else nil
                end
              }
              constants << { name: name, values: values } if values.any?
            end
          end
        end
        node.child_nodes.compact.each { |child| find_constant_arrays(child, constants) }
      end

      # `%w[...].freeze` and `Ractor.make_shareable(%w[...])` are the array itself, frozen.
      def unwrap_frozen(node)
        loop do
          break node unless node.is_a?(Prism::CallNode)

          if node.name == :freeze && node.arguments.nil?
            node = node.receiver
          elsif node.name == :make_shareable && node.receiver&.slice&.delete_prefix("::") == "Ractor" && node.arguments&.arguments&.size == 1
            node = node.arguments.arguments.first
          else
            break node
          end
        end
      end

      def extract_detailed_macros_from_ast(source_data)
        encryption = []
        normalizations = []
        tokens = []

        source_data[:macros].each do |m|
          written = m[:written] || {}
          case m[:macro]
          when :encrypts
            encryption << { field: m[:attribute], options: written }
          when :normalizes
            entry = { field: m[:attribute], transformation: written[:with], options: written.except(:with).presence }
            normalizations << entry.compact
          when :generates_token_for
            entry = { purpose: m[:attribute] }
            entry[:expires_in] = written[:expires_in] if written[:expires_in]
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
      LIFTED_ASSOCIATION_OPTIONS = %i[
        through dependent class_name foreign_key polymorphic optional source_type join_table association_foreign_key
      ].freeze
      BOOLEAN_ASSOCIATION_OPTIONS = %i[polymorphic optional].freeze

      # What the record already says another way, or what Rails keeps for itself.
      # A has_many's foreign key (or query_constraints, its 7.1 spelling) stays listed: its
      # record carries reflection's default key too, so only the declaration says it is not the default.
      UNLISTED_ASSOCIATION_OPTIONS = [ *(LIFTED_ASSOCIATION_OPTIONS - [ :foreign_key ]), :anonymous_class ].freeze

      # Every other option the association declares, each as display text:
      # its callbacks, extensions, counter cache and the rest.
      def declared_association_options(type, options)
        return nil unless options.is_a?(Hash)

        shown = options.except(*UNLISTED_ASSOCIATION_OPTIONS)
        shown = shown.except(:required, :foreign_key, :query_constraints) if type.to_s == "belongs_to"
        shown.to_h { |key, value| [ key.to_s, association_option_text(value) ] }.presence
      end

      def association_option_text(value)
        case value
        when Symbol then ":#{value}"
        when Module then value.name.to_s
        when Proc then "(proc)"
        when Array then "[#{value.map { |v| association_option_text(v) }.join(', ')}]"
        when Hash then "{ #{value.map { |k, v| "#{k}: #{association_option_text(v)}" }.join(', ')} }"
        else value.to_s
        end
      end

      # A habtm join_table built from the class's affixes, as the table it names.
      def with_join_tables(associations, path, class_name)
        own = nil
        associations.map do |assoc|
          table = assoc.is_a?(Hash) && assoc.dig(:options, :join_table)
          next assoc unless table.is_a?(String) && table.include?("\#{")

          own ||= TableName.declarations(model_source(path), class_name, app.root).slice(:table_name_prefix, :table_name_suffix)
          resolved = TableName.affixed(table, own, app.root)
          resolved ? assoc.merge(join_table: resolved, options: assoc[:options].merge(join_table: resolved)) : assoc
        end
      end

      def booted_association_shape(assoc)
        return assoc unless assoc.is_a?(Hash)

        shaped = assoc.merge(assoc[:name] ? { name: assoc[:name].to_s } : {})
        options = assoc[:options]
        return with_default_foreign_key(shaped) unless options.is_a?(Hash)

        lifted = LIFTED_ASSOCIATION_OPTIONS.each_with_object(shaped) do |key, acc|
          next unless options.key?(key) && !acc.key?(key)

          value = options[key]
          # `dependent: nil` is a declaration of nothing, and the booted tier
          # drops it; lifting it as "" renders `.dependent(:)`.
          next if value.nil?

          acc[key] = if BOOLEAN_ASSOCIATION_OPTIONS.include?(key) then value
          elsif value.is_a?(Array) then value.map(&:to_s)
          else value.to_s
          end
        end
        lifted = with_rails_option_rules(lifted, options)
        declared = declared_association_options(lifted[:type], options)
        with_default_foreign_key(declared ? lifted.merge(declared_options: declared) : lifted)
      end

      # What Rails does with two options: `required:` on a belongs_to sets
      # `optional:` to its negation, and Rails 7.1 takes `query_constraints:`
      # as the foreign key (7.2 deprecates it, 8.0 refuses it).
      def with_rails_option_rules(assoc, options)
        required = literal_boolean(options[:required]) if options.key?(:required)
        assoc = assoc.merge(optional: !required) if assoc[:type] == "belongs_to" && !required.nil?
        keys = options[:query_constraints]
        assoc = assoc.merge(foreign_key: keys.map(&:to_s)) if keys.is_a?(Array) && !assoc.key?(:foreign_key)
        assoc
      end

      # Reflection answers a belongs_to's key when none is declared: the name plus _id.
      def with_default_foreign_key(assoc)
        return assoc unless assoc[:type] == "belongs_to" && !assoc.key?(:foreign_key)
        return assoc if assoc[:computed_name] || assoc[:name].to_s.empty?

        assoc.merge(foreign_key: SchemaConventions.reference_column_name(assoc[:name]))
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
                               sti: nil, parent_model: nil, primary_key: nil)
        own = own_body(source_walk(path), class_name)
        calls = singleton_lookup([ [ class_name, path ], *Array(inherited_from) ])
        data, unread, bases_unread, hidden = merge_class_and_bases(own, class_name, calls, inherited_from, file: path,
                                                                   commits_in_order: static_commits_in_order)
        own_methods = ActionResolver.own_methods(own[:methods], class_name)
        scope_names = Array(data[:scopes]).filter_map { |scope| scope[:name]&.to_s }.to_set
        static_instance_methods = own_methods.select { |m| m[:scope] == :instance && m[:visibility] == :public }.map { |m| m[:name].to_s }
        static_class_methods = own_methods.select { |m| m[:scope] == :class && m[:visibility] == :public }
                                          .map { |m| m[:name].to_s }.reject { |name| scope_names.include?(name) }
        details = {
          confidence: Confidence::STATIC,
          table_name: table_name || TableName.stem(path),
          primary_key: primary_key,
          associations: with_join_tables(reject_excluded_associations(data[:associations]), path, class_name),
          validations: static_validations(data, [ path, *Array(inherited_from).map(&:last) ]),
          custom_validates: extract_custom_validates_from_ast(data),
          custom_validate_conditions: custom_validate_conditions(data),
          custom_validate_blocks: custom_validate_blocks(data),
          scopes: Array(data[:scopes]).reject { |s| s[:default] },
          default_scopes: default_scopes(data),
          # The booted tier answers a Hash of attribute => value map, and
          # every renderer destructures one; the listener's records are a
          # different shape under the same key.
          enums: static_enums(data[:enums]),
          enum_options: extract_enum_options_from_ast(data).presence,
          # Same shape as the booted tier: a Hash keyed by callback type. The
          # listener hands back a flat Array, and every consumer filters on
          # `callbacks.is_a?(Hash)` - so passing it through rendered "No models
          # with callbacks found" and then raised a TypeError on a Hash lookup
          # against an Array.
          callbacks: group_callbacks_by_type(data[:callbacks]),
          callback_conditions: callback_conditions(data[:callbacks]),
          concerns: static_concerns(data[:mixins], path),
          concern_sources: concern_sources(static_concerns(data[:mixins], path), data[:mixins], booted: false),
          concerns_hidden: (hidden.size if hidden.any?),
          concern_callbacks: concern_callbacks(data[:callbacks]),
          concerns_unread: (unread if unread.any?),
          bases_unread: (bases_unread if bases_unread.any?),
          commit_order_unread: commit_order_unread(data[:callbacks]),
          conditional_declarations: declarations(data[:conditional]),
          foreign_declarations: declarations(data[:foreign]),
          macros: data[:macros],
          methods: own_methods,
          # The keys the booted tier carries, so a consumer finds them here
          # too. `source_instance_methods` is the same set on both tiers; the
          # counts here are the source's, where booted ones add reflection's.
          instance_methods: static_instance_methods.first(PAYLOAD_METHOD_CAP),
          instance_method_count: static_instance_methods.size,
          source_instance_methods: static_instance_methods,
          class_methods: static_class_methods.first(PAYLOAD_METHOD_CAP),
          class_method_count: static_class_methods.size,
          file: file,
          sti: sti,
          # A concrete app model this one subclasses; it shares that model's table.
          parent_model: parent_model
        }
        details.merge!(extract_macros_from_ast(data, path))
        details.merge!(extract_detailed_macros_from_ast(data))
        type_column = static_type_column(details.delete(:setting_literals))
        details[:sti] = sti && type_column && !lacks_column?(details[:table_name], type_column) ? sti.merge(type_column: type_column) : nil
        downgrade_records(details.compact)
      end

      # Both tiers collect all six. The booted tier reads five of them off the
      # source too - a concern's `validate :x` reaches custom_validates, its
      # enum options reach enum_options - and reflection overwrites the sixth,
      # associations, on that tier.
      MERGED_CONCERN_KEYS = %i[associations validations scopes enums callbacks macros].freeze

      # The merged keys, plus what a mixin's macro methods declare only under a
      # condition the call cannot decide.
      WALKED_KEYS = [ *MERGED_CONCERN_KEYS, :conditional, :foreign ].freeze

      # Reflection answers these whether or not the concern's file was read,
      # so on the booted tier an unread concern costs the other keys only.
      REFLECTED_CONCERN_KEYS = %i[associations validations enums].freeze

      # The walk only collects: where a declaration lands waits for every class's walk.
      Walk = Struct.new(:own, :collected, :unread, :hidden, :skipped, :rank) do
        def self.empty(own) = new(own, {}, [], [], Set.new, 0)
      end

      def walk_class(own, class_name, calls, extra: [], file: nil, rank: 0)
        collected, unread, hidden, included, placement, skipped, blocks, mixed = ConcernMacros.collect(
          app.root.to_s, own[:mixins] || [],
          keys: [ *WALKED_KEYS, :expanded ], prefer: "model", within: class_name,
          cache: @source_cache, calls: calls, extra: extra, file: file
        )
        included_at = included_at(own, placement)
        every = extra.map(&:name).to_set
        bodies = method_bodies(own)
        mixins = mixed.map do |label, macro, defs, in_module|
          line, order = included_at.call(label)
          added, line = in_module || [ ConcernMacros::SingletonLookup.added_in(rank, line, bodies), line ]
          ConcernMacros::SingletonLookup::Mixin.new(label, macro, defs, added, [ line, order ], every.include?(placement.dig(label, 0)))
        end
        calls.add(rank, included, blocks, mixins)
        Walk.new(own, collected, unread, hidden, skipped, rank)
      end

      # Where a concern the walk read joins the class's chain: at the line
      # including it, after the concerns that include brought in before it.
      def included_at(own, placement)
        line_of = Array(own[:mixins]).reverse.to_h { |mixin| [ mixin[:name], mixin[:location].to_i ] }
        lambda do |name|
          top, order = placement[name]
          top ? [ line_of[top].to_i, order.to_i ] : [ 0, 0 ]
        end
      end

      # A walk's declarations where Ruby runs them: one in a method body, the class's own or a
      # module's, once per call running that body; a concern's where its code runs.
      def settle(walk, calls, expanded = nil)
        own, rank = walk.own, walk.rank
        collected = walk.collected.to_h do |key, entries|
          [ key, entries.flat_map { |entry| place(entry, rank, calls) }.then { |found| key == :callbacks ? found : found.map { |entry| entry.except(*CHAIN_KEYS) }.uniq } ]
        end
        own = without_expanded_calls(own, Array(collected.delete(:expanded)) + Array(expanded))
        callbacks = Array(own[:callbacks]).flat_map do |cb|
          method = own_method(own, cb[:location])
          next [ cb.merge(rank: rank) ] unless method
          next [] unless method[:scope] == :class

          calls.placed(cb, [ rank, method[:location] ], [ cb[:location] ])
        end
        own = own.merge(callbacks: callbacks + Array(collected.delete(:callbacks)))
        [ collected.empty? ? own : merge_inherited(own, collected), walk.unread, walk.hidden ]
      end

      def place(entry, rank, calls)
        entry.is_a?(Hash) ? calls.mixed_in(entry, rank) : [ entry ]
      end

      def own_method(own, line)
        ConcernMacros.enclosing(method_bodies(own), line)&.last
      end

      def method_bodies(own)
        Array(own[:methods]).filter_map { |m| [ m[:location]..m[:end_location], m ] if m[:location] && m[:end_location] }
      end

      # A `validates_translation :title` call the listener read as a validation
      # of its own is what the method declares, now read from its body.
      def without_expanded_calls(own, expanded)
        return own if expanded.blank?

        sites = expanded.to_set { |call| [ call[:method], call[:line] ] }
        own.merge(validations: Array(own[:validations]).reject { |v| sites.include?([ v[:kind].to_s, v[:location] ]) })
      end

      # The class's own concerns and its bases', walked to agreement: a method
      # one's `included` block calls runs in the class wherever the method is
      # defined, so a base's concern can release what the class's own walk
      # held back (OpenProject's WorkPackage::InexistentWorkPackage inherits
      # journals that way), and the class's concern what a base's did.
      #
      # Each side is walked again only when the other has since learned a call
      # that releases something it held back.
      def merge_class_and_bases(own, class_name, calls, bases, file:, commits_in_order:)
        extra = BaseMixins.models(app.root.to_s)
        mine = walk_class(own, class_name, calls, extra: extra, file: file)
        walked = walk_bases(bases, calls)
        ConcernMacros::MAX_DEPTH.times do
          known = Set.new(calls.sites_by_name.keys)
          break unless mine.skipped.intersect?(known)

          mine = walk_class(own, class_name, calls, extra: extra, file: file)
          held = walked.flat_map { |_name, walk| walk ? walk.skipped.to_a : [] }.to_set
          grown = Set.new(calls.sites_by_name.keys) - known
          walked = walk_bases(bases, calls) if held.intersect?(grown)
        end
        declared = base_declarations(calls, [ [ class_name, file ], *bases ])
        expanded = Array(declared.delete(:expanded)).group_by { |call| call[:rank] }
        data, unread, hidden = settle(mine, calls, expanded[0])
        data = merge_inherited(data, declared)
        settled = walked.map { |name, walk| walk ? [ name, walk.own, *settle(walk, calls, expanded[walk.rank]) ] : [ name, nil ] }
        data, *rest = merge_inherited_macros(data, unread, hidden, settled)
        [ data.merge(callbacks: chain_order(data[:callbacks], commits_in_order)), *rest ]
      end

      CHAIN_KEYS = %i[rank chain_at hook owner].freeze

      # What the class methods the app's base bodies give the class declare, at each call reaching them,
      # with the calls read that way (`:expanded`) by the rank they stand at.
      def base_declarations(calls, classes)
        found = Hash.new { |hash, key| hash[key] = [] }
        base_defs(classes).each do |node, definition|
          next unless node.is_a?(Prism::DefNode)

          sites = Array(calls.sites_by_name[definition.name]).compact
          expansion, = ConcernMacros.expand_calls(node, sites, [ *WALKED_KEYS, :expanded ], SourceIntrospector::LISTENER_MAP) do |entry, site|
            calls.placed(entry, definition.key, [ entry[:location] ], site)
          end
          expansion.each do |key, entries|
            found[key].concat(%i[callbacks expanded].include?(key) ? entries : entries.map { |entry| entry.except(*CHAIN_KEYS) }.uniq)
          end
        end
        found.to_h
      end

      # Rails builds the chain from the outermost base in, each class in the
      # order its body runs.
      def chain_order(callbacks, commits_in_order)
        sorted = Array(callbacks).each_with_index.sort_by do |cb, index|
          [ -cb[:rank].to_i, cb[:chain_at] || [ cb[:location].to_i, -1 ], index ]
        end
        run_order(callback_chain(without_skipped(sorted.map(&:first))), commits_in_order).map { |cb| cb.except(*CHAIN_KEYS) }
      end

      # A `skip_callback` removes the matching callback already in the chain;
      # with `if:`/`unless:` Rails keeps it under the negated condition.
      def without_skipped(callbacks)
        callbacks.each_with_object([]) do |cb, kept|
          next kept << cb unless cb[:skip]

          key = Listeners::CallbacksListener.chain_key(cb[:type])
          matching = ->(k) { Listeners::CallbacksListener.chain_key(k[:type]) == key && k[:method].to_s == cb[:method].to_s }
          conditions = (cb[:options] || {}).slice(:if, :unless)
          if conditions.empty?
            kept.reject!(&matching)
          else
            kept.map! { |k| matching.call(k) ? k.merge(options: negated_conditions(k[:options] || {}, conditions)) : k }
          end
        end
      end

      def negated_conditions(options, skip)
        flipped = { unless: skip[:if], if: skip[:unless] }.compact
        options.merge(flipped) { |_key, ours, theirs| [ *Array(ours), theirs ] }
      end

      # A prepended callback goes to the front and after callbacks run from the
      # back; ActiveModel prepends every after_*, after_commit only on request.
      def run_order(callbacks, commits_in_order)
        ordered = callbacks.dup
        callbacks.each_index.group_by { |i| Listeners::CallbacksListener.chain_key(callbacks[i][:type]) }.each_value do |slots|
          chain = slots.each_with_object([]) do |i, list|
            prepended?(callbacks[i], commits_in_order) ? list.unshift(callbacks[i]) : list.push(callbacks[i])
          end
          chain.reverse! if Listeners::CallbacksListener.after?(callbacks[slots.first][:type])
          slots.zip(chain) { |i, cb| ordered[i] = cb }
        end
        ordered
      end

      # An unknown setting keeps the transaction callbacks in declaration order.
      def prepended?(callback, commits_in_order)
        declared = callback.dig(:options, :prepend).to_s == "true"
        return declared unless Listeners::CallbacksListener.after?(callback[:type])
        return true unless Listeners::CallbacksListener.transaction?(callback[:type])

        declared || commits_in_order != false
      end

      # Rails 7.0 has no setting and always runs them last declared first.
      def booted_commits_in_order
        ActiveRecord.respond_to?(:run_after_transaction_callbacks_in_order_defined) &&
          ActiveRecord.run_after_transaction_callbacks_in_order_defined == true
      end

      # nil when the config cannot say: no config/application.rb, a version or
      # a value that is not a literal. A chain order has no way to carry a condition.
      def static_commits_in_order
        setting = framework_setting(:run_after_transaction_callbacks_in_order_defined=, since: 7.1)
        return (setting.value unless setting.value.is_a?(String)) if setting.assigned
        return nil if !setting.read || setting.version == Float::INFINITY

        setting.version.to_f >= 7.1
      end

      # Only a chain with two of them can be out of order.
      def commit_order_unread(callbacks)
        return nil unless static_commits_in_order.nil?

        chains = Array(callbacks).select { |cb| Listeners::CallbacksListener.transaction?(cb[:type]) }.map { |cb| Listeners::CallbacksListener.chain_key(cb[:type]) }
        true if chains.tally.values.any? { |count| count > 1 }
      end

      # Each base read with its concerns; a base's concern macro that sits in a
      # class method runs for the class that calls it, the child as often as
      # the base.
      def walk_bases(bases, calls)
        Array(bases).each_with_index.map do |(name, path), index|
          own = sti_base_source(path)
          [ name, own && walk_class(own_body(own, name), name, calls, file: path, rank: index + 1) ]
        end
      end

      # An STI child inherits its base's macros along with its table.
      # Reflection inherits three of the six keys - associations, validations
      # and enums - and the other three are read off the file, so both tiers
      # walk the chain the way they walk the concerns. Read nearest base
      # first, so the closer declaration wins over the further one.
      # A base the walk could not read is answered apart from the unread
      # concerns: it is a class, not a concern, and a child with no concerns
      # never reaches the line that names them.
      def merge_inherited_macros(data, unread, hidden, walked)
        bases_unread = []
        walked.each do |name, own, base, base_unread, base_hidden|
          if own.nil?
            bases_unread |= [ name ]
            next
          end

          # A connection is declared on an abstract base, so the child says which one.
          macros = Array(base[:macros]).map { |m| m[:macro] == :connects_to ? m.merge(declared_in: name) : m }
          data = merge_inherited(data, base.slice(*WALKED_KEYS).merge(macros: macros))
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

        @source_cache[path] ||= source_walk(path)
      rescue StandardError
        nil
      end

      # The size the whole introspector agrees a file is worth reading. Both
      # tiers ask this before the first walk, so a second walk over the same
      # file has to ask it too or the two disagree.
      # Asked for a base file once per model that inherits it, so a run asks
      # the filesystem once.
      def readable_source?(path)
        return false unless path

        RunCache.fetch([ :readable_source, path.to_s ]) do
          File.exist?(path) && File.size(path) <= RailsAiContext.configuration.max_file_size
        rescue SystemCallError
          false
        end
      end

      DECLARATION_KEYS = %i[declaration receiver condition from_concern].freeze

      # What a mixin's macro method declares only under a condition the call
      # cannot decide, or inside a block it evaluates on another receiver
      # (`translation_class.instance_eval`): named, and never counted as the model's.
      def declarations(found)
        found = dedup(found) { |c| c.slice(*DECLARATION_KEYS) }
        found.map { |c| c.slice(*DECLARATION_KEYS) } if found.any?
      end

      def merge_inherited(mine, inherited)
        merged = mine.merge(inherited) { |_key, ours, theirs| Array(ours) + Array(theirs) }
        merged[:associations] = dedup(merged[:associations]) { |a| [ a[:type], a[:name] ] }
        # Default scopes stack base first; a named scope the model redefines is its own.
        base_defaults, base_named = Array(inherited[:scopes]).partition { |s| s[:default] }
        own_defaults, own_named = Array(mine[:scopes]).partition { |s| s[:default] }
        merged[:scopes] = dedup(base_defaults + own_defaults + own_named + base_named) { |s| s[:default] ? [ s[:name], s[:body] ] : s[:name] }
        merged[:enums] = dedup(merged[:enums]) { |e| e[:name].to_s }
        # `encrypts :secret` on a base and again on the child is one macro, and
        # the consumers read it as a list of attributes. The key is the
        # declaration: the line it was read at differs between two files, and
        # the concern tag differs between two ways of reaching one file.
        # Bases first, the order Rails runs them: a child's `ignored_columns +=` adds to its base's list.
        merged[:macros] = dedup(Array(inherited[:macros]) + Array(mine[:macros])) { |m| m.except(:from_concern, :location, :owner) }
        merged[:callbacks] = Array(inherited[:callbacks]) + Array(mine[:callbacks])
        # One source line read twice is still one declaration: a concern the
        # model and one of its bases both include is walked once per class, and
        # `included do` runs once. Two validations really written twice differ
        # by the line they are on and both stay.
        merged[:validations] = dedup(merged[:validations]) { |v| v }
        merged
      end

      SYMBOL_TARGET = /\A[a-z_]\w*[?!]?\z/

      # Rails keeps the later of a symbol declared twice; two blocks stay two.
      def callback_chain(callbacks)
        keys = callbacks.each_with_index.map do |c, i|
          c[:method].to_s.match?(SYMBOL_TARGET) ? [ Listeners::CallbacksListener.chain_key(c[:type]), c[:method].to_s ] : i
        end
        keys.zip(callbacks).reverse.uniq(&:first).reverse.map(&:last)
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

      # Mongoid documents are invisible to ActiveRecord reflection, so both
      # tiers parse them from source. Fields and embedded relations come from
      # the Mongoid listener; shared-name macros (belongs_to, has_many,
      # validates, scope) come from the regular listener stack.
      def mongoid_static_models
        entries = mongoid_candidates
        models = mongoid_model_names(entries)
        entries.each_with_object({}) do |(class_name, entry), result|
          if entry[:error]
            result[class_name] = { error: entry[:error] }
            next
          end
          next unless models.include?(class_name)

          result[class_name] = if entry[:source].include?("Mongoid::Document")
            mongoid_model_details(entry[:source], class_name, entry[:path]).merge(file: relative_to_root(entry[:path]))
          else
            # This walk keeps no candidate hash, so an AR model in a
            # hybrid app gets the table it assigns itself and the derived
            # stem otherwise - no namespace prefix, no STI parent.
            static_model_details(entry[:path], class_name, table_name: TableName.explicit(entry[:source], class_name, app.root))
          end
        rescue => e
          result[class_name] = { error: e.message }
        end
      end

      def mongoid_candidates
        RailsAiContext::PathResolver.model_dirs(app.root).each_with_object({}) do |models_dir, found|
          Dir.glob(File.join(models_dir, "**", "*.rb")).sort.each do |path|
            relative = path.sub("#{models_dir}/", "").sub(/\.rb\z/, "")
            next if relative == "application_record"

            begin
              next if File.size(path) > RailsAiContext.configuration.max_file_size

              source = model_source(path)
              next if source.nil? || mixin_path?(relative, source) || abstract_class?(source)

              # The static tier never loads the app's inflector, so camelizing alone
              # would invent `Activitypub::` for an app that declares `ActivityPub::`.
              class_name = DeclaredConstant.resolve(source, relative.camelize)
              next if found.key?(class_name) || config.excluded_models.include?(class_name)

              declaration = DeclaredConstant.declaration_for(DeclaredConstant.declarations(source), class_name)
              found[class_name] = { path: path, source: source, superclass: declaration&.superclass, nesting: declaration&.nesting }
            rescue => e
              found[relative.camelize] ||= { error: e.message }
            end
          end
        end
      end

      # app/models also holds plain classes. A model includes Mongoid::Document,
      # subclasses a record base, or subclasses a model.
      def mongoid_model_names(entries)
        names = entries.filter_map do |name, entry|
          name if entry[:source]&.include?("Mongoid::Document") || (entry[:superclass] && model_base?(entry[:superclass]))
        end.to_set
        loop do
          added = entries.select do |name, entry|
            parent = entry[:superclass]
            !names.include?(name) && parent &&
              SuperclassChain.resolve_in_scope(name, parent, nesting: entry[:nesting]) { |q| q if names.include?(q) }
          end.keys
          break if added.empty?

          names.merge(added)
        end
        names
      end

      # The file's source, or nil when it is unreadable or over the size cap.
      # ponytail: keeps every model file's text for the instance's life; re-read if memory matters.
      def model_source(path)
        return @model_sources[path] if @model_sources.key?(path)

        @model_sources[path] = RailsAiContext::SafeFile.read(path, max_size: RailsAiContext.configuration.max_file_size)
      end

      # A path the read could not answer falls through to the path walk, which raises. A class
      # nested in the model's file includes for itself, not for the model.
      def own_body(data, class_name)
        data.merge(mixins: ConcernMembership.owned_by(data[:mixins], class_name, root: app.root),
                   callbacks: ConcernMembership.owned_by(data[:callbacks], class_name),
                   macros: ConcernMembership.owned_by(data[:macros], class_name),
                   scopes: ConcernMembership.owned_by(data[:scopes], class_name).map { |scope| scope.except(:owner) })
      end

      def source_walk(path)
        source = model_source(path)
        source ? SourceIntrospector.walk_source(source) : SourceIntrospector.call(path)
      end

      # The class files' side of the lookup, read only when a concern asks: their class-body
      # calls and their own class methods, `alias_method` in `class << self` included.
      def singleton_lookup(classes)
        reader = lambda do
          ranks = {}
          defs = []
          readable = classes.each_with_index.select { |(_, path), _| path && readable_source?(path) }
          found = readable.each_with_object({}) do |((name, path), rank), into|
            source = model_source(path)
            scope = class_scope((source ? AstCache.parse_string(source) : AstCache.parse(path)).value, name)
            own = scope.select { |node| node.is_a?(Prism::CallNode) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) }
                       .group_by { |node| node.name.to_s }
            own.each_value { |sites| sites.each { |site| ranks[site.__id__] = rank } }
            defs.concat(ConcernMacros::SingletonLookup.own_defs(scope, rank))
            ConcernMacros::Run.merge_calls(into, own)
          rescue StandardError, ScriptError => e
            # A file the walk cannot read calls nothing it can see.
            RailsAiContext.debug_fail(e, nil, label: "class calls of #{path}")
          end
          defs.concat(base_defs(classes).map(&:last))
          ConcernMacros::SingletonLookup::Read.new(found, ranks, defs, classes.size)
        end
        ConcernMacros::SingletonLookup.new(reader)
      end

      # [node, definition] for each class method a base body outside app/models gives the class: one
      # reopening ApplicationRecord at that base's rank, the rest at the outermost; each after its base's file.
      def base_defs(classes)
        application = classes.index { |name, _| name == "ApplicationRecord" }
        BaseMixins.bodies(app.root.to_s).flat_map do |body|
          rank = body.target == "ApplicationRecord" ? application : classes.size
          next [] unless rank

          ConcernMacros::SingletonLookup.member_defs(body.statements, rank, body.order)
        end
      end

      # The nodes the class body runs with the class as self: the node opening a
      # method, nested class or `class << x` is there, its body is not.
      def class_scope(tree, class_name)
        short = class_name.to_s.split("::").last.to_s
        roots = AstWalk.each(tree).select { |node| node.is_a?(Prism::ClassNode) && node.constant_path.slice.split("::").last.casecmp?(short) }
        roots.empty? ? scope_nodes(tree) : roots.flat_map { |root| scope_nodes(root.body) }
      end

      def scope_nodes(node, found = [])
        return found unless node

        found << node
        case node
        when Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode then found
        else node.child_nodes.compact.each_with_object(found) { |child, into| scope_nodes(child, into) }
        end
      end

      MONGOID_MACROS = -> { Listeners::GenericMacroListener.new(%i[field embeds_many embeds_one embedded_in store_in index], call_source: %i[index]) }

      def mongoid_model_details(source, class_name, path)
        data = SourceIntrospector.walk_source(source, {
          mongoid: MONGOID_MACROS,
          associations: Listeners::AssociationsListener,
          validations: Listeners::ValidationsListener,
          scopes: Listeners::ScopesListener,
          callbacks: Listeners::CallbacksListener,
          methods: Listeners::MethodsListener,
          mixins: Listeners::MixinsListener
        })
        # A concern's `included` block declares into the document before the body that follows it.
        from_concerns, = ConcernMacros.collect(app.root.to_s, data[:mixins], keys: %i[mongoid], prefer: "model", within: class_name,
                                               listeners: { mongoid: MONGOID_MACROS, mixins: Listeners::MixinsListener }, file: path)
        macros = Array(from_concerns[:mongoid]) + Array(data[:mongoid])
        calls = singleton_lookup([ [ class_name, path ] ])
        calls.add(0, {}, {}, [])
        own = own_body(data.merge(mixins: []), class_name)
        # Mongoid sets after_commit without prepend, as Rails 7.0 does, so it runs last declared first.
        callbacks = chain_order(settle(Walk.empty(own), calls).first[:callbacks], false)
        details = {
          confidence: Confidence::STATIC,
          mongoid: true,
          fields: macros.select { |m| m[:macro] == :field }.map { |m| mongoid_field(m) },
          embeds: macros.select { |m| %i[embeds_many embeds_one embedded_in].include?(m[:macro]) }
                        .map { |m| { type: m[:macro], name: m[:args].first } },
          indexes: macros.select { |m| m[:macro] == :index }.map { |m| m[:text] },
          # An embedded child is a relation like any other, so every count and the graph see it.
          associations: reject_excluded_associations(Array(data[:associations]) + embedded_associations(macros)),
          validations: data[:validations],
          scopes: own[:scopes],
          # Same shape as the booted tier: a Hash keyed by callback type. The
          # listener hands back a flat Array, and every consumer filters on
          # `callbacks.is_a?(Hash)` - so passing it through rendered "No models
          # with callbacks found" and then raised a TypeError on a Hash lookup
          # against an Array.
          callbacks: group_callbacks_by_type(callbacks),
          callback_conditions: callback_conditions(callbacks),
          methods: data[:methods]
        }
        collection = macros.find { |m| m[:macro] == :store_in }&.dig(:options, :collection)
        details[:collection] = collection if collection
        downgrade_records(details)
      end

      # A default Mongoid computes (a lambda) is left out, as the replay leaves a computed column default.
      def mongoid_field(macro)
        options = macro[:options]
        default = SchemaConventions.format_default(options[:default]) unless options[:default] == Confidence::INFERRED
        { name: macro[:args].first, type: options[:type], default: default }.compact
      end

      def embedded_associations(macros)
        macros.select { |m| %i[embeds_many embeds_one].include?(m[:macro]) }.map do |m|
          { name: m[:args].first.to_s, type: m[:macro].to_s, class_name: m[:options][:class_name]&.to_s }.compact
        end
      end
    end
  end
end
