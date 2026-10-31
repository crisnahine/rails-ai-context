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
        @left_out = EagerLoad.dir(app.root, kind: "app/models")
        @unloadable = {}
        models = discover_models

        result = models.each_with_object({}) do |model, hash|
          hash[model.name] = extract_model_details(model)
        rescue => e
          hash[model.name] = { error: e.message }.merge(raised_model_facts(model))
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
        lookup = @static_lookup = table_lookup(candidates)
        sti_parents = candidates.keys.to_h { |name| [ name, lookup.sti_parent(name) ] }
        bases = declared_bases(candidates)
        models = candidates.each_with_object({}) do |(class_name, candidate), result|
          # Hidden from the listing, kept in the walk: its children still
          # inherit its table and its declarations.
          next if config.excluded_models.include?(class_name) || candidate[:hidden]

          if candidate[:error]
            result[class_name] = { error: candidate[:error], file: candidate[:file] }.compact
            next
          end

          if candidate[:unreadable]
            # app/models holds POROs too, and a file the walk could not read
            # might be one. The entry says what it knows and claims a table
            # only where a child's inheritance says it is a model.
            table = TableName.for_class(class_name, lookup) if bases.include?(class_name)
            result[class_name] = { error: candidate[:unreadable], file: candidate[:file],
                                   table_name: table&.table, table_set_by: table&.set_by }.compact
            next
          end

          # An abstract base is dropped from the result and kept in the walk:
          # it is not a model of the app, and it is how its children reach what
          # it declares.
          next if candidate[:abstract]
          next unless model_class?(class_name, candidates)

          if hidden_ancestor?(class_name, candidates)
            result[class_name] = { error: "inherits from a file under sensitive_patterns, so its table and declarations are not read", file: candidate[:file], hidden_base: true }.compact
            next
          end

          # Resolved before the details, so the rescue below states it rather
          # than calling again: a second raise from the same call would escape
          # the rescue meant to contain the first.
          table = TableName.for_class(class_name, lookup)
          result[class_name] = static_model_details(candidate[:path], class_name, file: candidate[:file], table: table,
                                                    inherited_from: declaring_bases(class_name, candidates),
                                                    sti: static_sti_info(class_name, sti_parents),
                                                    parent_model: sti_parents[class_name])
        rescue => e
          # Kept: the file, which a pack model cannot derive from its name, and
          # the table and parent, or a subclass reads as a second table owner.
          result[class_name] = { error: e.message, file: candidate[:file], table_name: table&.table, table_set_by: table&.set_by,
                                   parent_model: sti_parents[class_name] }.compact
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
        reader.table?(table) && column != RailsAiContext::Confidence::INFERRED && !reader.column?(table, column)
      end

      # Rails' default column, the literal a class sets, or nil where `inheritance_column = nil` turns STI off.
      def static_type_column(source_data)
        setting = Array(source_data[:macros]).select { |m| m[:macro] == :model_setting && m[:setting] == "inheritance_column" }.last
        setting ? setting[:literal].presence : "type"
      end

      # A model file the app cannot load leaves its class out of reflection,
      # and leaving it out here answers that the model does not exist and that
      # its table has no model at all. The file is a fact the source walk
      # already holds, so the name is kept with the load error and with the
      # table the static tier reads off that same file.
      def unloadable_models
        return {} if @unloadable.nil? || @unloadable.empty?

        candidates = static_candidates
        lookup = table_lookup(candidates)
        @unloadable.each_with_object({}) do |(class_name, error), entries|
          candidate = candidates[class_name]
          # Other roots hold generators and gem subclasses too; static lists one only as a model.
          next if @outside_model_dirs&.include?(class_name) && !static_model?(class_name, candidates)

          table = candidate && TableName.for_class(class_name, lookup)
          entries[class_name] = {
            error: error,
            file: candidate&.dig(:file),
            table_name: table&.table,
            table_set_by: table&.set_by,
            parent_model: candidate && lookup.sti_parent(class_name)
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
        hidden = SourceScan.hidden_model_paths(app.root).to_h { |record| [ record.path_name, { hidden: true, unreadable: "file is under sensitive_patterns" } ] }
        SourceScan.model_paths(app.root).each_with_object(hidden) do |record, found|
          begin
            source = model_source(record.path) if File.size(record.path) <= RailsAiContext.configuration.max_file_size
            if source.nil?
              found[record.path_name] ||= unread_candidate(record) unless skip_unread?(record)
              next
            end

            next if mixin_path?(record.path_name.underscore, source)

            path_name = SourceScan.concerns_name(record.path_name, source)
            declarations = DeclaredConstant.declarations(source, path_name: path_name)
            declaration = DeclaredConstant.declaration_for(declarations, path_name)
            # A module file is named as it declares itself: camelize knows none of the app's acronyms.
            class_name = declaration&.name || DeclaredConstant.resolve(source, path_name)
            # Two files can declare one class (an app reopening a model to add methods);
            # the one that names a superclass defines the model, and a file named for it
            # wins over one that only shares another class's file.
            previous = found[class_name]
            next if previous && !shares_file?(previous) && (previous[:superclass] || declaration&.superclass.nil?)

            # A module file declares no class and is kept for the prefix and
            # the suffix alone: they belong to the namespace, not to any one
            # model.
            found[class_name] = class_candidate(record, source, class_name, declaration)
            add_sibling_candidates(found, record, source, class_name)
          rescue => e
            # The file is known here whatever failed, and a consumer with none
            # derives app/models/<name>.rb, which a pack model does not have.
            found[SourceScan.concerns_name(record.path_name, source.to_s)] = { error: e.message, file: record.file }.compact
          end
        end
      end

      # Eager loading loads every class a model file declares, so a second one
      # with a superclass is a candidate too; modelhood is decided afterwards.
      def add_sibling_candidates(found, record, source, class_name)
        DeclaredConstant.declarations(source, all: true).each do |sibling|
          next if sibling.name == class_name || sibling.superclass.nil? || found.key?(sibling.name)

          found[sibling.name] = class_candidate(record, source, sibling.name, sibling).merge(stem: sibling.name.demodulize.underscore)
        end
      end

      def class_candidate(record, source, class_name, declaration)
        {
          path: record.path,
          file: record.file,
          superclass: declaration&.superclass,
          superclass_nesting: declaration&.nesting,
          abstract: abstract_in?(source, class_name)
        }.merge(TableName.declarations(source, class_name, app.root))
      end

      # An abstract base beside the class in its file does not take it along.
      def abstract_in?(source, class_name)
        own_text?(source, class_name) { |text| abstract_class?(text) }
      end

      # Whether the block holds for the class's own body text where the file declares
      # the class, or else for the whole file, for a form whose body cannot be told apart.
      def own_text?(source, class_name)
        return yield(source) unless DeclaredConstant.declarations(source, all: true).any? { |d| d.name == class_name }

        DeclaredConstant.class_bodies(AstCache.parse_string(source).value, class_name).any? { |body| yield(body.slice) }
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
          resolved = candidate[:superclass] && resolve_superclass(name, candidates)
          found << resolved if resolved
        end
      end

      def hidden_ancestor?(class_name, candidates, seen = [])
        return false if seen.include?(class_name)

        parent = candidates.dig(class_name, :superclass) && resolve_superclass(class_name, candidates)
        !!parent && (candidates.dig(parent, :hidden) || hidden_ancestor?(parent, candidates, seen + [ class_name ]))
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
        return true if TableName.model_base?(parent)

        resolved = resolve_superclass(class_name, candidates)
        return model_class?(resolved, candidates, seen + [ class_name ]) if resolved
        # A class sharing a file often has a table's name without being a record
        # (a serializer model beside the one it serializes), so it is never guessed.
        return false if shares_file?(candidates[class_name])

        outside_model_base?(class_name, candidates)
      end

      # A gem parent (`ActsAsTaggableOn::Tag`, not ActiveHash) is an ActiveRecord base when a database's dump holds
      # a table it gives the class; with no schema, or a dump not on disk, when the class declares associations or scopes.
      def outside_model_base?(class_name, candidates)
        candidate = candidates[class_name]
        return false unless candidate[:path]
        parent = table_lookup(candidates).outside_parent(class_name)
        # The frameworks' own classes (`ActiveRecord::Relation`, `ActiveModel::Model`) are never a model's base.
        return false if parent.to_s.start_with?("ActiveRecord::", "ActiveModel::")
        # Nor is a class this process already holds that is not a record (StandardError, Struct).
        return false if known_non_record?(parent)

        if SchemaReader.for(app.root).tables.any?
          names = TableName.outside_names(class_name, table_lookup(candidates))
          return true if names.any? { |table| SchemaReader.for(app.root).table?(table) }

          secondary = secondary_dump_tables
          return names.any? { |table| secondary.include?(table) } if secondary
        end

        data = sti_base_source(candidate[:path])
        return false unless data

        source = model_source(candidate[:path])
        classes = DeclaredConstant.declarations(source, all: true).map(&:name)
        modules = DeclaredConstant.module_nodes(AstCache.parse_string(source)&.value)
        %i[associations scopes].any? { |key| ConcernMembership.owned_with_modules(data[key], class_name, classes, data[:mixins], modules).any? }
      end

      # Walked segment by segment so an autoload is never run: app code must not load here.
      def known_non_record?(name)
        klass = name.to_s.delete_prefix("::").split("::").reduce(Object) do |scope, segment|
          break nil unless scope.is_a?(Module) && scope.const_defined?(segment, false) && !scope.autoload?(segment)

          scope.const_get(segment, false)
        end
        klass.is_a?(Class) && !(defined?(ActiveRecord::Base) && klass <= ActiveRecord::Base)
      rescue NameError
        false
      end

      # Ruby resolves a bare superclass from the enclosing namespace outward,
      # so `Admin::Report < Post` means the top-level Post unless Admin
      # declares one.
      def resolve_superclass(from, candidates)
        table_lookup(candidates).superclass(from)
      end

      # One per walk, so each superclass is resolved once for every class that reads it.
      def table_lookup(candidates)
        (@table_lookups ||= {}.compare_by_identity)[candidates] ||=
          TableName::Lookup.new(candidates, settings: ActiveRecordSettings.for(app.root), unread_settings: ActiveRecordSettings.unread(app.root),
                                            isolated_prefixes: TableName.namespace_prefixes(app.root), model: ->(name) { model_class?(name, candidates) },
                                            dump_tables: ->(names) { dump_tables(names) })
      end

      # A gem parent's candidate tables the primary's schema holds, else those another database's dump holds.
      def dump_tables(names)
        reader = SchemaReader.for(app.root)
        primary = names.select { |table| reader.table?(table) }
        primary.any? ? primary : names.select { |table| secondary_dump_tables&.include?(table) }
      end

      # A class declared in a file named for another class.
      def shares_file?(candidate)
        candidate&.key?(:stem)
      end

      # The tables every other database's dump holds; nil when one of them is not on disk to read.
      def secondary_dump_tables
        RunCache.fetch([ :secondary_dump_tables, app.root.to_s ]) do
          AppDatabases.for(app.root).reject(&:primary).filter_map(&:dump).each_with_object(Set.new) do |dump, tables|
            break nil unless File.exist?(dump.path)

            found = dump.format == :ruby ? SchemaReader.new(dump.path).tables : StructureSqlReader.parse(SafeFile.read(dump.path).to_s)[:tables]
            tables.merge(found.keys)
          end
        end
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
        resolved = resolve_superclass(class_name, candidates)
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

      # The booted tier rejects `abstract_class?`, so the static tier must too
      # or the same app gets two model counts. A namespaced base is one of
      # these (Ci::ApplicationRecord, SecApplicationRecord), and
      # the root application_record is not the only one to leave out.
      # Both forms Rails accepts. A generated ApplicationRecord says
      # `primary_abstract_class`, so reading the assignment alone left the app's
      # own base looking like a model with a table.
      def abstract_class?(source)
        return false unless source.include?("abstract_class")

        code = RubySource.code_only(source)
        code.match?(/^[^\S\n]*self\.abstract_class\s*=\s*true/) ||
          code.match?(/^[^\S\n]*primary_abstract_class\b/)
      end

      # A file under any concerns/ that is not named for a class. One that is
      # may be a model: some apps keep one in app/models/concerns itself.
      def mixin_path?(relative, source)
        return false unless relative.split("/").include?("concerns")

        SourceScan.concern_class(source, SourceScan.concerns_name(relative.camelize, source)).nil?
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

      def sensitive_source?(model)
        located = Object.const_source_location(model.name)&.first
        return PathResolver.sensitive?(app.root, located) if located.is_a?(String)

        # Ruby 3.1 names no file for a constant it reloaded; the scan of the model files still knows it.
        @hidden_model_names ||= SourceScan.hidden_model_paths(app.root).to_set(&:path_name)
        @hidden_model_names.include?(model.name)
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
            sensitive_source?(model) ||
            DeclaredConstant.renamed?(model) ||
            config.excluded_models.include?(model.name)
        end

        known = models.map(&:name).to_set
        @outside_model_dirs = Set.new
        # A nested concerns directory is a namespace, so a class under one is a model;
        # under the top-level one only a file that declares a class is read on.
        SourceScan.model_paths(app.root, base_model: model_base_check).each do |record|
          path_name = record.path_name
          if path_name.start_with?("Concerns::")
            source = model_source(record.path).to_s
            path_name = SourceScan.concerns_name(path_name, source)
          end
          # A class whose body raised is registered holding what ran before the raise.
          if EagerLoad.raised(record.path)
            half_built = DeclaredConstant.named(model_source(record.path).to_s, path_name)
            models.reject! { |model| model.name == half_built }
            known.delete(half_built)
          end
          next if known.include?(path_name)
          next if config.excluded_models.include?(path_name)
          next if path_name != record.path_name && mixin_path?(record.path_name.underscore, source)

          # The path does not name the class: an app inflection only changes
          # case, so activitypub/activity.rb camelizes to a constant the app
          # does not have and the file was listed as a model that will not
          # load. A root pushed under a namespace declares a prefix the path
          # lacks. Read only where the camelized name is not already loaded, so
          # a booted run does not parse every model file to learn nothing.
          class_name = DeclaredConstant.named(model_source(record.path).to_s, path_name)
          next if known.include?(class_name)
          next if config.excluded_models.include?(class_name)

          # Never required here either: a file that does not compile, or
          # whose class body needs one that does not (see EagerLoad). Why is
          # the answer for that model.
          if (reason = @left_out.to_h[record.path] || EagerLoad.skipped(record.path))
            @unloadable[class_name] = reason
            @outside_model_dirs << class_name unless model_dir_file?(record.path)
            next
          end

          begin
            klass = class_name.constantize
            next unless klass < ActiveRecord::Base && !klass.abstract_class?
            models << klass
            known << class_name
          rescue StandardError, ScriptError => e
            # A file that raises as it loads costs itself alone, and its name is recorded:
            # a file that exists for a class reflection lacks is no missing model.
            @unloadable[class_name] = e.message.to_s.lines.first.to_s.strip
            @outside_model_dirs << class_name unless model_dir_file?(record.path)
          end
        end

        models.uniq.sort_by(&:name)
      end

      # The facts the static tier keeps for a model that raised.
      def raised_model_facts(model)
        { file: relative_to_root(model_source_path(model)), table_name: raised_table_name(model), parent_model: concrete_parent(model) }.compact
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "raised_model_facts")
      end

      # A computed table name may be what raised, and it costs only itself.
      def raised_table_name(model)
        model.table_name
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "raised_table_name")
      end

      def concrete_parent(model)
        parent = model.superclass
        parent.name if parent < ActiveRecord::Base && !parent.abstract_class?
      end

      def extract_model_details(model)
        # Reflection covers associations, validations and enums, but scopes,
        # macros and custom validates are read off the file - so the concerns
        # and the superclasses are merged here too, or the static tier
        # out-answers this one.
        own_path = model_source_path(model)
        data, unread, bases_unread, hidden, = class_declarations(model.name, own_path, booted_declaring_bases(model),
                                                                 read: ->(path, _source, _name) { path == own_path ? introspect_source(model) : cached_walk(path) },
                                                                 commits_in_order: booted_commits_in_order, chains: model.__callbacks.keys.map(&:to_s))
        facts = record_facts(data, unread, bases_unread, hidden, own_path, relative_to_root(own_path))
        concerns = booted_concerns(model, data[:mixins])
        ModelRecord.build(facts, ModelRecord::Reflection.new(
                                   table: TableName::Answer.new(table: model.table_name, primary_key: model_primary_key(model)),
                                   associations: extract_associations(model, data),
                                   # Reflection has no text for a Proc condition and names `validates_with` by kind only,
                                   # so the list is read off the source; an unreadable file falls back to reflection.
                                   validations: booted_validations(model, data),
                                   enums: extract_enums(model),
                                   concerns: concerns,
                                   concern_sources: concern_sources(concerns, data[:mixins], booted: true),
                                   class_methods: extract_class_methods_from_ast(model, data),
                                   instance_methods: extract_instance_methods_from_ast(model, data),
                                   # The model's own public instance methods: reflection's list is inflated by an
                                   # attribute method per column as soon as anything instantiates the model.
                                   source_instance_methods: own_source_methods(model, data),
                                   sti: extract_sti_info(model),
                                   parent_model: concrete_parent(model),
                                   ignored_columns: model.ignored_columns.map(&:to_s).presence,
                                   # Reflection answers here, over an `establish_connection` the source walk read.
                                   own_connection: (true if own_connection?(model, facts.macros))
                                 ))
      end

      # What both tiers read off the walked source the same way.
      def record_facts(data, unread, bases_unread, hidden, path, file)
        ModelRecord::Facts.new(data: data, unread: unread, bases_unread: bases_unread, hidden: hidden, file: file, rails_version: rails_version,
                               macros: extract_macros_from_ast(data, path).merge(extract_detailed_macros_from_ast(data)))
      end

      # A model on a connection of its own (`establish_connection`) reads a database the schema section did not list.
      def own_connection?(model, details)
        !details[:database] && model.connection_specification_name != ActiveRecord::Base.connection_specification_name
      rescue StandardError => e
        RailsAiContext.debug_fail(e, false, label: "own_connection?")
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
            declared.any? { |v| declares?(v, validator, attributes, model.name) }
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
      def declares?(declaration, validator, attributes, owner)
        return validator_class_name(declaration, owner) == validator.class.name if declaration[:kind] == "validates_with"

        overlap = (Array(declaration[:attributes]) & attributes).any?
        overlap && (declaration[:kind] == validator.kind.to_s || declaration[:kind].start_with?("validates_"))
      end

      # The constant Ruby finds for the written name, looked up from the module or class whose body wrote it.
      def validator_class_name(declaration, owner)
        written = declaration[:validator].to_s
        scope = declaration[:from_concern] || owner
        nesting = scope ? [ scope, *SuperclassChain.nesting_of(scope) ] : []
        SuperclassChain.resolve_in_scope(nil, written, nesting: nesting) { |c| (found = c.safe_constantize).is_a?(Module) && found.name } || written
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
        implicit_presence(static_required(data, default)) + declared + for_rails_version(added)
      end

      # Each belongs_to declaration adds its own validator and a later optional one removes none, so a
      # subclass's `optional: true` keeps its base's, where the base declared it.
      def static_required(data, default)
        found = static_required_belongs_to(reject_excluded_associations(data[:declared_associations]), default)
        found.reject { |entry| entry.is_a?(Array) && found.include?(entry.first) }.uniq
      end

      # `self.belongs_to_required_by_default = false` in a class body wins over
      # the app's default, and a subclass inherits its parent's.
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
          since = v[:since_rails]
          next nil if since && version && Gem::Version.new(version) < Gem::Version.new(since)

          v = v.except(:since_rails)
          next v.merge(added_by: "#{v[:added_by]}, assuming Rails #{since}+ as Gemfile.lock names no Rails version") if since && version.nil?

          before = v[:before_rails]
          next v unless before || (version.nil? && v[:added_by] == "has_secure_password")
          next nil if before && (version.nil? || Gem::Version.new(version) >= Gem::Version.new(before))

          v = v.except(:before_rails)
          version ? v : v.merge(added_by: "#{v[:added_by]}, assuming Rails 7.1+ as Gemfile.lock names no Rails version")
        end
      end

      def rails_version
        return @rails_version if defined?(@rails_version)

        @rails_version = GemLock.for(app.root).rails_version
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

      # Reflection already applied optional:, required: and the app's default; listed in validator order.
      def booted_required_belongs_to(model)
        belongs_to = model.reflect_on_all_associations(:belongs_to).map { |a| a.name.to_s }.reject { |name| excluded_association?(name) }
        model.validators.select { |v| required_presence?(v) }.flat_map { |v| v.attributes.map(&:to_s) }.uniq & belongs_to
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

        "#{node.name.to_s.delete_suffix('=')} = #{ModelRecord.source_slice(value.slice)} is true"
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

      # A module a gem's inherited hook mixes into every model (Kaminari) is left out; one the app includes or defines stays.
      def base_gem_modules(model, mixins)
        written = ConcernMembership.from_mixins(mixins)
        gem_bases(model).flat_map { |base| base.ancestors - every_model_modules }.uniq.select do |mod|
          !mod.is_a?(Class) && mod.name && !written.include?(mod.name) && !ConcernPaths.find_file(app.root.to_s, mod.name)
        end
      end

      def abstract_bases(model)
        model.ancestors.select { |klass| klass.is_a?(Class) && klass < ActiveRecord::Base && klass != model && klass.abstract_class? }
      end

      # The app's bases a gem's inherited hook reaches as it reaches the model (Kaminari: each direct ActiveRecord::Base child).
      def gem_bases(model)
        bases = abstract_bases(model)
        return bases unless model.superclass == ActiveRecord::Base

        bases | DeclaredConstant.carried(ActiveRecord::Base.subclasses).select(&:abstract_class?)
      end

      def every_model_modules
        @every_model_modules ||= ActiveRecord::Base.ancestors
      end

      # The source's mixins, plus the modules `devise :a, :b` includes by
      # Devise's own naming rule, so both tiers agree for Devise.
      def static_concerns(mixins, path)
        ConcernMembership.from_mixins(local_mixin_names(mixins, path)) | ConcernMembership.payload(devise_modules(path))
      end

      # `include Trackable` in Payment's body reaches Payment::Trackable where the
      # file or the app's concerns declare that module, as Ruby's lexical lookup does.
      def local_mixin_names(mixins, path)
        source = path && model_source(path)
        local = source ? DeclaredConstant.module_nodes(AstCache.parse_string(source)&.value) : {}
        root = app.root.to_s
        # The model's own file answers through `local`, which knows the line each module is written at.
        exists = lambda do |name|
          found, file = ConcernPaths.declared(root, name)
          found if found && !(path && File.identical?(file, File.expand_path(path, root)))
        end
        Array(mixins).map do |mixin|
          nesting = DeclaredConstant.record_nesting(mixin)
          later = -> { nesting.empty? ? [] : ConcernPaths.ancestors(root, nil, nil, nesting.first) - [ nesting.first ] }
          mixin.merge(name: ConcernMembership.local_name(mixin, local, exists: exists, later: later))
        end
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
        detail[:as] = assoc.options[:as].to_s if assoc.options[:as]
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
        connected = model.connected? && model.table_exists?
        return nil if type_column.empty?
        return nil if connected ? !model.columns_hash.key?(type_column) : lacks_column?(model.table_name, type_column)

        children = DeclaredConstant.carried(model.subclasses).map(&:name).sort

        parent = model.superclass
        # An abstract base (ApplicationRecord, or the one a second database connects through) holds no rows of its own.
        sti_parent = parent.name if parent && parent != ActiveRecord::Base && !parent.abstract_class?
        # A table db/schema.rb does not hold is in another database, so only a class family says it is STI.
        return nil if !connected && !SchemaReader.for(app.root).table?(model.table_name) && sti_parent.nil? && children.empty?

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
          elsif Listeners::MacrosListener::STORE_MACROS.include?(macro)
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
          elsif macro == :connects_to
            macros[:database] = { connects_to: m[:text], condition: m[:condition], declared_in: m[:declared_in], writing: m[:writing] }.compact
          elsif macro == :establish_connection
            macros[:own_connection] = true
          elsif macro == :gem_macro
            (macros[:gem_macros] ||= []) << m.slice(:text, :adds)
          elsif macro == :aasm
            (macros[:state_machines] ||= []) << m.slice(:column, :initial, :states, :events)
          end

          if Listeners::MacrosListener::BROADCAST_MACROS.include?(macro)
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
      # A location inside the app is the model's own file, unless a symlink
      # carries it out of the app, when it is not read; one outside it is
      # believed only when no model directory holds a file for the name, which
      # is what a gem's model looks like.
      def model_source_path(model)
        root = File.expand_path(app.root.to_s)
        located = Object.const_source_location(model.name)&.first
        if located && File.expand_path(located).start_with?("#{root}/")
          return PathResolver.linked_out?(located, root) || PathResolver.sensitive?(root, located) ? nil : located
        end

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
        through dependent class_name foreign_key polymorphic optional source_type join_table association_foreign_key as
      ].freeze
      BOOLEAN_ASSOCIATION_OPTIONS = %i[polymorphic optional].freeze

      # What the record already says another way, or what Rails keeps for itself. A has_many's declared
      # foreign key stays: its record carries reflection's default key too.
      UNLISTED_ASSOCIATION_OPTIONS = [ *(LIFTED_ASSOCIATION_OPTIONS - %i[foreign_key as]), :anonymous_class ].freeze

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

          own ||= @static_lookup ? TableName.affixes(class_name, @static_lookup) : TableName.declarations(model_source(path), class_name, app.root).slice(:table_name_prefix, :table_name_suffix)
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

      # `required:` on a belongs_to sets `optional:` to its negation; Rails 7.1 takes `query_constraints:` as the foreign key.
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

      # A Proc has no text, but the key stays, so a reader can tell the option is set.
      def sanitize_options(options)
        options.reject { |_k, v| v.is_a?(Regexp) }
               .transform_values { |value| value.is_a?(Proc) ? "(proc)" : sanitize_option_value(value) }
      end

      def sanitize_option_value(value)
        return value.map { |element| sanitize_option_value(element) } if value.is_a?(Array)
        return value if SANITIZED_SCALARS.any? { |type| value.is_a?(type) }

        value.to_s
      end

      # `<Plugin>::Patches::<Model>Patch` modules under the app's and its in-repo gems' lib/: an engine
      # includes them in to_prepare (a plugin's `patches`), outside any file the static walk reads.
      def unread_patches(class_name, mixins)
        included = Array(mixins).map { |m| m[:name].to_s.delete_prefix("::") }
        patch_index.fetch(class_name, []) - included
      end

      def patch_index
        @patch_index ||= begin
          root = app.root.to_s
          libs = [ File.join(root, "lib"), *PathResolver.code_roots(root).map { |r| File.join(r, "lib") }, *PathResolver.path_gem_libs(root) ]
          libs.uniq.flat_map { |lib| FileWalk.glob(lib, "**/patches/**/*_patch.rb", root: root) }.uniq
              .each_with_object(Hash.new { |h, k| h[k] = [] }) do |path, index|
                source = SafeFile.read(path) or next
                DeclaredConstant.module_nodes(AstCache.parse_string(source).value).each_key do |name|
                  model = name[/::Patches::(.+)Patch\z/, 1]
                  index[model] << name if model
                end
              end
        end
      end

      def static_model_details(path, class_name, file: relative_to_root(path), table: TableName::Answer.new, inherited_from: [],
                               sti: nil, parent_model: nil)
        data, unread, bases_unread, hidden, own = class_declarations(class_name, path, inherited_from, read: ->(file, _source, _name) { cached_walk(file) },
                                                                                                   commits_in_order: static_commits_in_order)
        facts = record_facts(data, unread, bases_unread, hidden, path, file)
        own_methods = ActionResolver.own_methods(own[:methods], class_name)
        scope_names = Array(data[:scopes]).filter_map { |scope| scope[:name]&.to_s }.to_set
        # The source's own public methods: the booted counts add reflection's.
        instance_methods = own_methods.select { |m| m[:scope] == :instance && m[:visibility] == :public }.map { |m| m[:name].to_s }
        class_methods = own_methods.select { |m| m[:scope] == :class && m[:visibility] == :public }
                                   .map { |m| m[:name].to_s }.reject { |name| scope_names.include?(name) }
        table = TableName::Answer.new(table: table.table || (TableName.stem(path) unless table.set_by), set_by: table.set_by, primary_key: table.primary_key)
        type_column = static_type_column(data)
        concerns = static_concerns(data[:mixins], path)
        ModelRecord.build(facts, ModelRecord::StaticCandidates.new(
                                   confidence: Confidence::STATIC,
                                   table: table,
                                   associations: with_join_tables(reject_excluded_associations(data[:associations]), path, class_name),
                                   validations: static_validations(data, [ path, *Array(inherited_from).map(&:last) ]),
                                   # `defined_enums` keys both levels with Strings, as reflection answers them.
                                   enums: static_enums(data[:enums]),
                                   concerns: concerns,
                                   concern_sources: concern_sources(concerns, data[:mixins], booted: false),
                                   class_methods: class_methods,
                                   instance_methods: instance_methods,
                                   source_instance_methods: instance_methods,
                                   sti: (sti.merge(type_column: type_column) if sti && type_column && !lacks_column?(table.table, type_column)),
                                   # A concrete app model this one subclasses; it shares that model's table.
                                   parent_model: parent_model,
                                   patches_unread: unread_patches(class_name, data[:mixins]).presence,
                                   commit_order_unread: commit_order_unread(data[:callbacks]),
                                   ignored_columns: facts.macros[:ignored_columns],
                                   own_connection: facts.macros[:own_connection]
                                 ))
      end

      # Both tiers collect all six. The booted tier reads five of them off the
      # source too - a concern's `validate :x` reaches custom_validates, its
      # enum options reach enum_options - and reflection overwrites the sixth,
      # associations, on that tier.
      MERGED_CONCERN_KEYS = %i[associations validations scopes enums callbacks macros].freeze

      # The merged keys, plus what a mixin's macro methods declare only under a
      # condition the call cannot decide.
      WALKED_KEYS = [ *MERGED_CONCERN_KEYS, :conditional, :foreign ].freeze

      # The model walks keep callbacks on a library's chains; class_declarations checks each against the model.
      LISTENERS = SourceIntrospector::LISTENER_MAP.merge(callbacks: -> { Listeners::CallbacksListener.new(library_chains: true) }).freeze

      # Reflection answers these whether or not the concern's file was read,
      # so on the booted tier an unread concern costs the other keys only.
      REFLECTED_CONCERN_KEYS = %i[associations validations enums].freeze

      # The class's declarations through its concerns and its bases, as ClassDeclarations walks them,
      # merged the way a model reads them: [data, unread concerns, unread bases, hidden concerns, own body].
      # `chains` are the callback chains the booted model holds; nil keeps only the callbacks the source shows a chain for.
      def class_declarations(class_name, file, bases, read:, commits_in_order:, chains: nil)
        found = ClassDeclarations.for(class_name, lookup: ->(_name) { }, keys: [ *WALKED_KEYS, :expanded ], listeners: LISTENERS, root: app.root.to_s,
                                                  prefer: "model", file: file, bases: Array(bases), read: read,
                                                  text: ->(path) { model_source(path) }, cache: @source_cache)
        own = found.chain.first.own
        data = merged_declarations(own, found)
        unread = found.unread.reject { |entry| entry.reason == :base }.map(&:name)
        bases_unread = found.unread.select { |entry| entry.reason == :base }.map(&:name)
        data = data.merge(declared_associations: data[:associations], associations: reflected(data[:associations]), callbacks: chain_order(on_known_chains(data[:callbacks], chains), commits_in_order))
        [ data, unread, bases_unread, found.hidden, own ]
      end

      def on_known_chains(callbacks, chains)
        Array(callbacks).filter_map do |cb|
          next cb unless cb.is_a?(Hash) && cb[:library_chain]

          cb.except(:library_chain) if chains&.include?(cb[:library_chain])
        end
      end

      # Rails keeps one reflection per name, the last declared; the subclass copies its base's reflections.
      def reflected(associations)
        Array(associations).reverse.uniq { |a| a[:name].to_s }.reverse
      end

      # The chain in the order the class body runs, outermost base first.
      def chain_order(callbacks, commits_in_order)
        run_order(callback_chain(without_skipped(Array(callbacks))), commits_in_order)
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
        # A bare set_callback appends; the model macros are what prepend an after callback.
        return declared if callback[:name] == "set_callback" || !Listeners::CallbacksListener.after?(callback[:type])
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

      # An STI child inherits its base's macros along with its table. Reflection inherits three of the
      # six keys - associations, validations and enums - and the other three are read off the file, so
      # both tiers walk the chain the way they walk the concerns.
      def merged_declarations(own, found)
        declared = found.declarations
        depth = found.chain.each_with_index.to_h { |link, index| [ link.name, index ] }
        # The nearest class first, each class's own body before its concerns.
        nearest = ->(entries) { Array(entries).each_with_index.sort_by { |e, i| [ depth[e[:declared_in]].to_i, e[:from_concern] ? 1 : 0, i ] }.map(&:first) }
        bare = ->(entries) { Array(entries).map { |e| e.is_a?(Hash) ? e.except(:declared_in) : e } }
        defaults, named = Array(declared[:scopes]).partition { |s| s[:default] }
        data = own.merge(
          associations: bare.call(declared[:associations]),
          callbacks: bare.call(declared[:callbacks]),
          # Default scopes stack base first; a named scope the model redefines is its own.
          scopes: dedup(bare.call(defaults) + bare.call(nearest.call(named))) { |s| s[:default] ? [ s[:name], s[:body] ] : s[:name] },
          enums: dedup(bare.call(nearest.call(declared[:enums]))) { |e| e[:name].to_s },
          # Base first, in run order, as Rails lists `validators`. One source line read twice is still one
          # declaration; two validations really written twice differ by the line they are on and both stay.
          validations: dedup(bare.call(declared[:validations])) { |v| v },
          # `encrypts :secret` on a base and again on the child is one macro, and the consumers read it as
          # a list of attributes; bases first, the order Rails runs them. A connection is declared on an
          # abstract base, so the child says which one.
          macros: dedup(Array(declared[:macros]).map { |m| m[:macro] == :connects_to ? m : m.except(:declared_in) }) { |m| m.except(:from_concern, :location, :owner) },
          conditional: bare.call(nearest.call(declared[:conditional])),
          foreign: bare.call(nearest.call(declared[:foreign]))
        )
        # A base's concerns are the child's too: the child's record already
        # carries what they declared, and its callbacks credit them by name.
        data.merge(mixins: found.chain.drop(1).select(&:own).reduce(Array(own[:mixins])) { |mixins, link| mixins | Array(link.own[:mixins]) })
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
        done = {}
        entries.each_key { |class_name| mongoid_entry(class_name, entries, models, done) }
        entries.keys.select { |class_name| done[class_name] }.to_h { |class_name| [ class_name, done[class_name].except(:settled_callbacks) ] }
      end

      # A subclass of a document is a document; its parent is read first.
      def mongoid_entry(class_name, entries, models, done)
        return done[class_name] if done.key?(class_name)

        entry = entries[class_name]
        return done[class_name] = { error: entry[:error] } if entry[:error]
        return done[class_name] = nil unless models.include?(class_name)

        done[class_name] = false
        parent_name = entry[:superclass] && SuperclassChain.resolve_in_scope(class_name, entry[:superclass], nesting: entry[:nesting]) { |q| q if models.include?(q) }
        parent = parent_name && mongoid_entry(parent_name, entries, models, done)
        add_discriminator_field(parent) if parent.is_a?(Hash) && parent[:mongoid]
        done[class_name] = if entry[:document] || (parent.is_a?(Hash) && parent[:mongoid])
          mongoid_model_details(entry[:source], class_name, entry[:path], parent: parent && parent[:mongoid] ? [ parent_name, parent ] : nil)
            .merge(file: relative_to_root(entry[:path]))
        else
          # A hybrid app's AR model gets only its own or the derived table here: no namespace prefix, no STI parent.
          static_model_details(entry[:path], class_name, table: TableName::Answer.new(table: TableName.explicit(entry[:source], class_name, app.root)))
        end
      rescue => e
        done[class_name] = { error: e.message }
      end

      # Mongoid adds `_type` to a document class when another subclasses it,
      # after the fields it already has, and the subclass copies the list.
      def add_discriminator_field(parent)
        return if Array(parent[:fields]).any? { |f| f[:name].to_s == "_type" }

        parent[:fields] = Array(parent[:fields]) + [ { name: :_type, type: "String", implicit: "a subclassed document" } ]
      end

      def mongoid_candidates
        RailsAiContext::PathResolver.model_dirs(app.root).each_with_object({}) do |models_dir, found|
          RailsAiContext::FileWalk.glob(models_dir, "**/*.rb", root: app.root.to_s).each do |path|
            relative = path.sub("#{models_dir}/", "").sub(/\.rb\z/, "")
            next if relative == "application_record"

            begin
              next if File.size(path) > RailsAiContext.configuration.max_file_size

              source = model_source(path)
              next if source.nil? || mixin_path?(relative, source)

              path_name = SourceScan.concerns_name(relative.camelize, source)

              # The static tier never loads the app's inflector, so camelizing alone
              # would invent `Activitypub::` for an app that declares `ActivityPub::`.
              class_name = DeclaredConstant.resolve(source, path_name)
              next if found.key?(class_name) || config.excluded_models.include?(class_name)

              add_sibling_documents(found, path, source, class_name)
              next if abstract_in?(source, class_name)

              declaration = DeclaredConstant.declaration_for(DeclaredConstant.declarations(source, path_name: path_name), class_name)
              found[class_name] = document_candidate(path, source, class_name, declaration)
            rescue => e
              found[path_name || relative.camelize] ||= { error: e.message }
            end
          end
        end
      end

      # Every other class the file declares that is a document or names a superclass.
      def add_sibling_documents(found, path, source, class_name)
        DeclaredConstant.declarations(source, all: true).each do |sibling|
          next if sibling.name == class_name || found.key?(sibling.name) || config.excluded_models.include?(sibling.name)
          next if abstract_in?(source, sibling.name)

          entry = document_candidate(path, source, sibling.name, sibling)
          found[sibling.name] = entry if entry[:document] || sibling.superclass
        end
      end

      # A document beside a plain class does not make that class a document.
      def document_candidate(path, source, class_name, declaration)
        { path: path, source: source, superclass: declaration&.superclass, nesting: declaration&.nesting,
          document: own_text?(source, class_name) { |text| text.include?("Mongoid::Document") } }
      end

      # app/models also holds plain classes. A model includes Mongoid::Document,
      # subclasses a record base, or subclasses a model.
      def mongoid_model_names(entries)
        names = entries.filter_map do |name, entry|
          name if entry[:document] || (entry[:superclass] && TableName.model_base?(entry[:superclass]))
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

      def cached_walk(path) = (@source_cache[path] ||= source_walk(path))

      MODEL_LISTENERS = LISTENERS.merge(foreign_evals: Listeners::ForeignEvalsListener).freeze

      def source_walk(path)
        source = model_source(path)
        walked = source ? SourceIntrospector.walk_source(source, MODEL_LISTENERS) : SourceIntrospector.walk(path, MODEL_LISTENERS)
        walked[:declared_classes] = DeclaredConstant.declarations(source, all: true).map(&:name) if source
        CallSiteExpansion.class_body_foreign(Array(walked[:foreign_evals]), walked.except(:foreign_evals))
      end

      MONGOID_MACROS = -> { Listeners::GenericMacroListener.new(%i[field embeds_many embeds_one embedded_in store_in index], call_source: %i[index]) }
      MONGOID_LISTENERS = {
        mongoid: MONGOID_MACROS,
        associations: Listeners::AssociationsListener,
        validations: Listeners::ValidationsListener,
        scopes: Listeners::ScopesListener,
        callbacks: Listeners::CallbacksListener,
        methods: Listeners::MethodsListener,
        mixins: Listeners::MixinsListener
      }.freeze

      def mongoid_model_details(source, class_name, path, parent: nil)
        data = SourceIntrospector.walk_source(source, MONGOID_LISTENERS)
        # A concern's `included` block declares into the document before the body that follows it.
        from_concerns = ConcernMacros.collect(app.root.to_s, data[:mixins], keys: %i[mongoid], prefer: "model", within: class_name,
                                              listeners: { mongoid: MONGOID_MACROS, mixins: Listeners::MixinsListener }, file: path).collected
        # A module in the document's file that it includes counts, as no concern walk reads it here.
        classes = DeclaredConstant.declarations(source, all: true).map(&:name)
        modules = DeclaredConstant.module_nodes(AstCache.parse_string(source)&.value)
        beside = lambda do |key|
          ConcernMembership.owned_with_modules(data[key], class_name, classes, data[:mixins], modules).map { |record| record.except(:owner) }
        end
        macros = Array(from_concerns[:mongoid]) + beside.call(:mongoid)
        own = { associations: beside.call(:associations), validations: beside.call(:validations), scopes: beside.call(:scopes) }
        parent_name, inherited = parent
        settled = ClassDeclarations.for(class_name, lookup: ->(_name) { }, keys: %i[callbacks expanded], listeners: MONGOID_LISTENERS, root: app.root.to_s,
                                                    file: path, bases: [], read: ->(_file, _source, _name) { data.merge(mixins: [], declared_classes: classes) })
                                   .declarations[:callbacks]
        # A parent's callbacks join the chain as a base's do, ahead of the subclass's.
        settled = Array(inherited&.dig(:settled_callbacks)) + settled
        # Mongoid sets after_commit without prepend, as Rails 7.0 does, so it runs last declared first.
        callbacks = chain_order(settled, false)
        declared = macros.select { |m| m[:macro] == :field }.map { |m| mongoid_field(m) }
        mixins = ConcernMembership.owned_by(data[:mixins], class_name)
        details = {
          confidence: Confidence::STATIC,
          mongoid: true,
          fields: with_implicit_fields(declared, mixins, own[:associations], inherited),
          embeds: macros.select { |m| %i[embeds_many embeds_one embedded_in].include?(m[:macro]) }
                        .map { |m| { type: m[:macro], name: m[:args].first } },
          indexes: macros.select { |m| m[:macro] == :index }.map { |m| m[:text] },
          # An embedded child is a relation like any other, so every count and the graph see it.
          associations: reject_excluded_associations(Array(own[:associations]) + embedded_associations(macros)),
          validations: own[:validations],
          scopes: own[:scopes],
          # Same shape as the booted tier: a Hash keyed by callback type. The
          # listener hands back a flat Array, and every consumer filters on
          # `callbacks.is_a?(Hash)` - so passing it through rendered "No models
          # with callbacks found" and then raised a TypeError on a Hash lookup
          # against an Array.
          callbacks: ModelRecord.group_callbacks_by_type(callbacks),
          callback_conditions: ModelRecord.callback_conditions(callbacks),
          callback_sources: ModelRecord.callback_sources(callbacks),
          methods: data[:methods],
          settled_callbacks: settled
        }
        if inherited
          { fields: :name, embeds: :name, associations: :name, scopes: :name }.each do |key, name|
            mine = Array(details[key]).map { |entry| entry[name].to_s }
            details[key] = Array(inherited[key]).reject { |entry| mine.include?(entry[name].to_s) } + Array(details[key])
          end
          details[:validations] = (Array(inherited[:validations]) + Array(details[:validations])).uniq
          details[:parent_model] = parent_name
        end
        embedded = macros.find { |m| m[:macro] == :embedded_in }
        embedded_in = embedded ? embedded_parent(embedded) : inherited&.dig(:embedded_in)
        if embedded_in
          details[:embedded_in] = embedded_in
        else
          # Mongoid's collection_name: store_in's, else the root class's name tableized with "/" as "_".
          details[:collection] = macros.find { |m| m[:macro] == :store_in }&.dig(:options, :collection) ||
                                 inherited&.dig(:collection) || class_name.tableize.tr("/", "_")
        end
        ModelRecord::StaticCandidates.new.finish(details)
      end

      # The fields each Mongoid::Timestamps module adds, by the module's name.
      MONGOID_TIMESTAMPS = {
        "Mongoid::Timestamps" => %w[created_at updated_at],
        "Mongoid::Timestamps::Short" => %w[c_at u_at],
        "Mongoid::Timestamps::Created" => %w[created_at],
        "Mongoid::Timestamps::Created::Short" => %w[c_at],
        "Mongoid::Timestamps::Updated" => %w[updated_at],
        "Mongoid::Timestamps::Updated::Short" => %w[u_at]
      }.freeze

      # The fields Mongoid defines without a `field` line, in the order
      # `Model.fields` lists them: every document's `_id`, the timestamps an
      # included Mongoid::Timestamps adds, the declared fields, then the foreign
      # key each belongs_to or has_and_belongs_to_many keeps. A subclass takes
      # its parent's list, so only the root of a hierarchy adds `_id`.
      def with_implicit_fields(declared, mixins, associations, inherited)
        named = declared.map { |f| f[:name].to_s }.to_set
        leading = []
        leading << { name: :_id, type: "BSON::ObjectId", implicit: "every document" } unless inherited
        Array(mixins).select { |m| m[:ancestor] && m[:receiver].nil? }.each do |mixin|
          module_name = mixin[:name].to_s.delete_prefix("::")
          MONGOID_TIMESTAMPS.fetch(module_name, []).each { |name| leading << { name: name.to_sym, type: "Time", implicit: module_name } }
        end
        keys = Array(associations).flat_map { |assoc| mongoid_foreign_keys(assoc) }
        # A `field` line naming one of these redefines it where it already sits.
        unplaced = declared.to_h { |f| [ f[:name].to_s, f ] }
        placed = leading.map { |f| unplaced.delete(f[:name].to_s) || f }
        (placed + unplaced.values + keys.reject { |f| named.include?(f[:name].to_s) }).uniq { |f| f[:name].to_s }
      end

      # The key a relation keeps on this document; a polymorphic belongs_to
      # adds its type first, as Mongoid does.
      def mongoid_foreign_keys(assoc)
        options = assoc[:options].is_a?(Hash) ? assoc[:options] : {}
        written = assoc[:foreign_key] || options[:foreign_key]
        written = nil unless written.is_a?(String) || written.is_a?(Symbol)
        case assoc[:type].to_s
        when "belongs_to"
          key = { name: (written || "#{assoc[:name]}_id").to_sym, type: "Object", implicit: "belongs_to :#{assoc[:name]}" }
          polymorphic = assoc[:polymorphic] || options[:polymorphic] == true
          polymorphic ? [ { name: :"#{assoc[:name]}_type", type: "String", implicit: "belongs_to :#{assoc[:name]}, polymorphic: true" }, key ] : [ key ]
        when "has_and_belongs_to_many"
          [ { name: (written || "#{assoc[:name].to_s.singularize}_ids").to_sym, type: "Array", implicit: "has_and_belongs_to_many :#{assoc[:name]}" } ]
        else []
        end
      end

      # A default Mongoid computes (a lambda) is left out, as the replay leaves a computed column default.
      def mongoid_field(macro)
        options = macro[:options]
        default = SchemaConventions.format_default(options[:default]) unless options[:default] == Confidence::INFERRED
        { name: macro[:args].first, type: options[:type], default: default }.compact
      end

      def embedded_parent(macro)
        options = macro[:options] || {}
        return "#{macro[:args].first} (polymorphic)" if options[:polymorphic]

        options[:class_name]&.to_s || macro[:args].first.to_s.camelize
      end

      def embedded_associations(macros)
        macros.select { |m| %i[embeds_many embeds_one].include?(m[:macro]) }.map do |m|
          { name: m[:args].first.to_s, type: m[:macro].to_s, class_name: m[:options][:class_name]&.to_s }.compact
        end
      end
    end
  end
end
