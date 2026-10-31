# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Static analysis for common performance anti-patterns:
    # N+1 query risks, missing counter_cache, Model.all in controllers,
    # missing foreign key indexes.
    #
    # Model and class structure is read from the AST. N+1 risks come from
    # NPlusOneScan, which follows a loaded collection into the loops and
    # partials that walk it. Every finding here is a heuristic, not a fact.
    class PerformanceIntrospector < Base
      extend StaticTier
      static_tier :files_only

      # The run's sections so far; the models section answers which table a
      # model reads, so this section and the model tier never disagree.
      attr_writer :context

      def call
        model_data = load_model_data
        schemas, unchecked = database_schemas
        counter_cache = []
        fk_indexes = []
        schemas.each do |name, tables, foreign_keys|
          tag = ->(finding) { name ? finding.merge(database: name) : finding }
          counter_cache.concat(detect_missing_counter_cache(model_data, tables).map(&tag))
          fk_indexes.concat(detect_missing_fk_indexes(tables, model_data, foreign_keys).map(&tag))
        end

        {
          n_plus_one_risks: detect_n_plus_one,
          missing_counter_cache: counter_cache.uniq { |f| f.except(:database) },
          missing_fk_indexes: fk_indexes,
          model_all_in_controllers: detect_model_all_in_controllers(model_data),
          eager_load_candidates: detect_eager_load_candidates(model_data),
          summary: nil # populated below
        }.tap do |result|
          result[:unchecked_databases] = unchecked if unchecked.any?
          assumed = SchemaReader.for(root).mysql_order_assumed
          result[:assumed_key_order] = SchemaConventions.mysql_order_assumed_phrase(assumed) if assumed.positive?
          result[:summary] = build_summary(result)
        end
      end

      private

      # [[database name (nil for the primary), tables, foreign keys]], and { name:, reason: } for each database not read.
      def database_schemas
        reader = SchemaReader.for(root)
        schemas = [ [ nil, reader.tables, reader.foreign_keys ] ]
        unchecked = []
        databases = AppDatabases.for(root)
        # Rails names one file for the first database and the one named primary. It is read once, above.
        shared = databases.primary&.dump&.path
        databases.reject { |db| db.primary || db.replica || (shared && db.dump&.path == shared) }.each do |db|
          read = read_dump(db)
          read[:reason] ? unchecked << { name: db.name, reason: read[:reason] } : schemas << [ db.name, read[:tables], read[:foreign_keys] ]
        end
        [ schemas, unchecked ]
      end

      # { tables:, foreign_keys: } from the database's dump, or { reason: } saying why there is none to read.
      def read_dump(db)
        reason = db.missing_dump(root)
        return { reason: reason } if reason

        path = db.dump.path
        shown = path.delete_prefix("#{root.to_s.chomp('/')}/")

        content = SafeFile.read(path, max_size: RailsAiContext.configuration.max_schema_file_size)
        return { reason: "#{shown} is over max_schema_file_size" } unless content
        return SchemaReader.new(path).then { |schema| { tables: schema.tables, foreign_keys: schema.foreign_keys } } if db.dump.format == :ruby

        tables = StructureSqlReader.parse(content)[:tables]
        { tables: tables,
          foreign_keys: tables.values.flat_map { |table| Array(table[:foreign_keys]).map { |fk| { from: fk[:from_table], to: fk[:to_table], column: fk[:column] } } } }
      end

      # The models section when the run has one; otherwise the model tier is
      # asked directly, which is what a standalone call costs.
      def resolved_models
        @resolved_models ||= begin
          models = @context && @context[:models]
          if models.is_a?(Hash) && !models.key?(:error) && !models.key?(:unavailable)
            models
          else
            introspector = ModelIntrospector.new(app)
            booted? ? introspector.call : introspector.static_call
          end
        rescue StandardError => e
          RailsAiContext.debug_fail(e, {}, label: "resolved_models")
        end
      end

      # A hash lookup: TableName.of_model scans every model for a name it does
      # not hold, and this runs once per model.
      def model_table(class_name)
        table_of(class_name, resolved_models)
      end

      def declared_name(record)
        DeclaredConstant.resolve(record.source, record.path_name)
      end

      def load_model_data
        # A class with a file of its own is read from that file, never again as another file's neighbour.
        own_files = model_sources.map { |record| declared_name(record) }.to_set
        model_sources.flat_map do |record|
          ast = SourceIntrospector.walk_source(record.source, {
            associations: Listeners::AssociationsListener,
            column_macros: COLUMN_MACRO_LISTENER,
            mixins: Listeners::MixinsListener,
            counter_culture: -> { Listeners::GenericMacroListener.new(:counter_culture) }
          })

          declared = DeclaredConstant.declarations(record.source, all: true).map(&:name)
          modules = DeclaredConstant.module_nodes(AstCache.parse_string(record.source)&.value)
          primary = declared_name(record)
          # Another class the file declares is a model of its own wherever the model walk lists it.
          siblings = declared.select { |name| name != primary && !own_files.include?(name) && resolved_models.key?(name) }
          # The model walk says what is a model, whatever its superclass is written as.
          [ primary, *siblings ].select { |name| resolved_models.key?(name) }.map { |class_name| model_record(record, ast, class_name, declared, modules) }
        rescue => e
          RailsAiContext.debug_fail(e, [], label: "load_model_data")
        end
      end

      def model_record(record, ast, class_name, classes, modules)
        found = declarations(record, ast.merge(declared_classes: classes), class_name)
        # A name declared again is the last declaration, as Rails replaces the reflection.
        associations = Array(found.declarations[:associations]).reverse.uniq { |a| a[:name].to_s }.reverse
        of_type = ->(type) { associations.select { |a| a[:type] == type }.map { |a| { name: a[:name].to_s, options: a[:options] || {} } } }
        {
          name: class_name,
          file: record.file,
          table_name: model_table(class_name),
          has_many: of_type.call("has_many"),
          belongs_to: of_type.call("belongs_to"),
          macro_columns: macro_columns(found, class_name),
          counter_cultures: ConcernMembership.owned_with_modules(ast[:counter_culture], class_name, classes, ast[:mixins], modules)
                                             .map { |c| counter_culture_record(c) }
        }
      end

      # Tree gem macros, which declare a parent key, with the option that renames it.
      TREE_MACROS = { acts_as_tree: :foreign_key, acts_as_nested_set: :parent_column,
                      has_closure_tree: :parent_column_name }.freeze
      # paper_trail adds `has_many :versions, as: :item` when the app boots.
      VERSIONS_MACRO = :has_paper_trail
      # Gem macros that declare a column.
      # ponytail: a fixed list; a gem outside it declares columns the static walk cannot see.
      COLUMN_MACROS = [ *TREE_MACROS.keys, VERSIONS_MACRO ].freeze
      COLUMN_MACRO_LISTENER = -> { Listeners::GenericMacroListener.new(*COLUMN_MACROS) }
      CONCERN_LISTENERS = { associations: Listeners::AssociationsListener, column_macros: COLUMN_MACRO_LISTENER,
                            mixins: Listeners::MixinsListener, methods: Listeners::MethodsListener }.freeze

      # The associations and gem macros the model, its concerns and its bases declare, in one walk.
      def declarations(record, walked, class_name)
        ClassDeclarations.for(class_name, lookup: ->(name) { model_files[name] }, keys: %i[associations column_macros], listeners: CONCERN_LISTENERS,
                                          root: root, prefer: "model", source: record.source, file: record.path, cache: (@concern_cache ||= {}),
                                          read: ->(path, source, _name) { walked if source || path == record.path })
      end

      # The [table, column] a gem macro declares, in the model, its concerns or its bases.
      # The models section cannot carry it statically: the macro is a gem's.
      def macro_columns(found, class_name)
        Array(found.declarations[:column_macros]).map do |macro|
          options = macro[:options] || {}
          next [ versions_table(options, class_name), "item_id" ] if macro[:macro] == VERSIONS_MACRO

          [ model_table(class_name), (options[TREE_MACROS[macro[:macro]]] || "parent_id").to_s ]
        end.uniq
      end

      # Each class a model file declares, by the file declaring it.
      def model_files
        @model_files ||= model_sources.each_with_object({}) do |record, found|
          DeclaredConstant.declarations(record.source, all: true).each { |declaration| found[declaration.name] ||= record.path }
        end
      end

      # PaperTrail::Version reads `versions`; `versions: { class_name: }`, or the older `class_name:`, names another class.
      def versions_table(options, owner)
        written = options[:versions].is_a?(Hash) ? options[:versions][:class_name] : options[:class_name]
        return "versions" unless written.is_a?(String)

        table_of(TableName.resolve_class(written, owner) { |candidate| candidate if resolved_models.key?(candidate) } || written, resolved_models)
      end

      # The scan reads the run models section, so an association a concern or a
      # base declares is one it can follow.
      def detect_n_plus_one
        NPlusOneScan.new(root, resolved_models, booted: booted?).call
      rescue StandardError => e
        RailsAiContext.debug_fail(e, [], label: "detect_n_plus_one")
      end

      # A counter the app maintains itself is not a missing counter_cache:
      # adding one double-counts every create and makes a reset stick until
      # the next destroy.
      def app_written_counter_columns
        return @app_written_counter_columns if defined?(@app_written_counter_columns)

        writers = Set.new
        %w[app lib].each do |kind|
          SourceScan.each(root, kind: kind, skip_concerns: false) do |record|
            next unless record.source.include?("_count")

            writers.merge(counter_writes(AstCache.parse_string(record.source).value))
          end
        end
        @app_written_counter_columns = writers
      rescue StandardError => e
        @app_written_counter_columns = RailsAiContext.debug_fail(e, Set.new, label: "app_written_counter_columns")
      end

      COUNTER_COLUMN = /\A\w+_count\z/
      # Calls whose keys, symbols or SQL set a column's value.
      COUNTER_WRITE_CALLS = %i[
        update update! update_columns update_column update_attribute update_attribute! update_all update_counters
        increment increment! decrement decrement! increment_counter decrement_counter assign_attributes attributes=
        write_attribute []= new build create create! insert insert! insert_all insert_all! upsert upsert_all
      ].to_set.freeze

      # A comparison or an `order(x_count: :desc)` reads the column; only an assignment or a write call sets it.
      def counter_writes(tree)
        AstWalk.each(tree).flat_map do |node|
          case node
          when Prism::CallOperatorWriteNode, Prism::CallOrWriteNode, Prism::CallAndWriteNode then [ node.read_name.to_s ]
          when Prism::CallTargetNode then [ node.name.to_s.chomp("=") ]
          when Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::IndexAndWriteNode then written_columns(node.arguments)
          when Prism::CallNode
            if COUNTER_WRITE_CALLS.include?(node.name) then written_columns(node.arguments)
            elsif node.attribute_write? then [ node.name.to_s.chomp("=") ]
            else []
            end
          else []
          end
        end.grep(COUNTER_COLUMN)
      end

      def written_columns(arguments)
        return [] unless arguments

        AstWalk.each(arguments).flat_map do |node|
          case node
          when Prism::SymbolNode then [ node.unescaped ]
          when Prism::StringNode then node.unescaped.scan(/(\w+_count)\s*=/).flatten
          else []
          end
        end
      end

      def detect_missing_counter_cache(model_data, schema_data)
        missing = []
        models = model_data.to_h { |m| [ m[:name], m ] }

        model_data.each do |model|
          model[:has_many].each do |assoc|
            options = assoc[:options]
            # A :through association reads its records over another one, so
            # there is no belongs_to on the far side to carry the counter.
            next if options.key?(:through)

            assoc_name = assoc[:name]
            count_col = named_counter_column(options[:counter_cache]) || "#{assoc_name}_count"

            table = schema_data[model[:table_name]]
            next unless table
            next unless table[:columns].any? { |c| c[:name] == count_col }
            next if app_written_counter_columns.include?(count_col)

            belongs_to_model = association_model(model_data, assoc, model[:name])
            next unless belongs_to_model
            inverse = inverse_belongs_to(belongs_to_model, options, model[:name], models)
            inverse_name = inverse ? inverse[:name] : (options[:as] || model[:name].demodulize.underscore).to_s
            # Only the belongs_to pointing back here keeps this column, and only when its counter is on.
            next if inverse && belongs_to_counter_column(inverse[:options][:counter_cache], belongs_to_model[:name]) == count_col
            next if counter_culture_keeps?(belongs_to_model, inverse_name, count_col)

            missing << {
              model: model[:name],
              association: assoc_name,
              column: count_col,
              suggestion: "Add counter_cache: #{count_col == default_counter_column(belongs_to_model[:name]) ? "true" : ":#{count_col}"} " \
                          "to belongs_to :#{inverse_name} in #{belongs_to_model[:name]}"
            }
          end
        end

        missing
      end

      # The belongs_to on the child that points back at owner, found the way Rails pairs them:
      # inverse_of, then the foreign key, then the class it names, resolved from the child's namespace outward.
      def inverse_belongs_to(child, options, owner, models)
        candidates = child[:belongs_to]
        named = options[:as] || options[:inverse_of]
        return candidates.find { |b| b[:name] == named.to_s } if named

        if options[:foreign_key]
          by_key = candidates.find { |b| (b[:options][:foreign_key] || "#{b[:name]}_id").to_s == options[:foreign_key].to_s }
          return by_key if by_key
        end
        default = owner.demodulize.underscore
        resolved = candidates.to_h do |b|
          [ b, TableName.model_for((b[:options][:class_name] || b[:name].classify).to_s, child[:name], models) ]
        end
        of_owner = candidates.select { |b| resolved[b] == owner }
        # A name no model answers may still be the owner's; one another model answers is not.
        of_owner.find { |b| b[:name] == default } || of_owner.first || candidates.find { |b| b[:name] == default && resolved[b].nil? }
      end

      # The column a belongs_to's counter_cache writes, as reflection.rb's counter_cache_column reads it:
      # a name, a Rails 7.2+ hash's column: (active: false still writes it), or the child's own plural.
      def belongs_to_counter_column(counter, child)
        return if [ nil, false, "false", "nil" ].include?(counter)

        named_counter_column(counter) || default_counter_column(child)
      end

      def named_counter_column(counter)
        if counter.is_a?(Hash)
          # Before 7.2 Rails took the hash itself as the column name.
          return counter.to_s unless hash_counter_cache?

          counter = counter[:column]
        end
        counter.to_s if (counter.is_a?(String) || counter.is_a?(Symbol)) && !%w[true false nil].include?(counter.to_s)
      end

      def hash_counter_cache?
        return @hash_counter_cache if defined?(@hash_counter_cache)

        @hash_counter_cache = RailsVersion.at_least?(RailsVersion.of(root), "7.2")
      end

      def default_counter_column(child)
        "#{child.demodulize.underscore.pluralize}_count"
      end

      # counter_culture names its column `<child table>_count` unless column_name says
      # otherwise; a column_name it computes may be this column, so it is not flagged.
      def counter_culture_keeps?(child, relation, column)
        Array(child[:counter_cultures]).any? do |culture|
          next false unless culture[:relation] == relation.to_s

          named = culture.fetch(:column) { "#{child[:name].demodulize.tableize}_count" }
          named == :computed || named == column
        end
      end

      # A multi-level `counter_culture [:a, :b]` counts on a further model and has no relation here.
      def counter_culture_record(call)
        node = call[:option_nodes][:column_name]
        record = { relation: call[:args].first&.to_s }
        record[:column] = node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode) ? node.unescaped : :computed if node
        record
      end

      # The class an association declares is the one the app has;
      # `has_many :remarks, class_name: "Comment"` is answered by Comment, and
      # never by the Remark the name implies. When no model in the app answers
      # either, the row would name a file the reader cannot open, so it is not
      # written at all.
      def association_model(model_data, assoc, owner)
        return nil if assoc[:computed_name] && !assoc[:options][:class_name]

        by_name = model_data.to_h { |m| [ m[:name], m ] }
        wanted = TableName.resolve_class(assoc[:options][:class_name] || assoc[:name].classify, owner) do |candidate|
          candidate if by_name.key?(candidate)
        end
        by_name[wanted]
      end

      # A `*_id` column is a foreign key only when something says so (add_foreign_key,
      # belongs_to, has_many or has_one); `stripe_customer_id` is an external id.
      def foreign_key_columns(foreign_keys)
        Array(foreign_keys).each_with_object(Set.new) do |fk, found|
          column = fk[:column] || "#{fk[:to].to_s.singularize}_id"
          found << [ fk[:from].to_s, column.to_s ]
        end
      end

      # The column each association reads, concerns and bases included: a belongs_to's on
      # its own table, a has_many's on the other, both of a habtm join, none for :through.
      def association_columns(models)
        models.each_with_object(Set.new) do |(name, details), found|
          next unless details.is_a?(Hash) && details[:table_name]

          table = details[:table_name].to_s
          Array(details[:associations]).each do |assoc|
            options = assoc[:options].is_a?(Hash) ? assoc[:options] : {}
            next if assoc[:through] || options.key?(:through)

            key = (assoc[:foreign_key] || options[:foreign_key])&.to_s
            own_key = "#{name.to_s.demodulize.underscore}_id"
            written = assoc[:class_name] || options[:class_name] || AssociationClass.derived_name(assoc)
            other = TableName.resolve_class(written, name) { |candidate| candidate if models.key?(candidate) }
            case assoc[:type].to_s
            when "belongs_to"
              found << [ table, key || "#{assoc[:name]}_id" ]
            when "has_many", "has_one"
              found << [ table_of(other, models), key || (options[:as] ? "#{options[:as]}_id" : own_key) ]
            when "has_and_belongs_to_many"
              join = (assoc[:join_table] || options[:join_table] ||
                      HabtmJoinTables.join_table_name(table, table_of(other, models))).to_s
              other_key = assoc[:association_foreign_key] || options[:association_foreign_key]
              found << [ join, key || own_key ]
              found << [ join, (other_key || "#{assoc[:name].to_s.singularize}_id").to_s ]
            end
          end
        end
      end

      def macro_declared_columns(model_data)
        Array(model_data).each_with_object(Set.new) do |model, found|
          Array(model[:macro_columns]).each { |column| found << column }
        end
      end

      def table_of(class_name, models)
        TableName.of_model(class_name, models.slice(class_name)).table.to_s
      end

      def detect_missing_fk_indexes(schema_data, model_data = [], foreign_keys = [])
        missing = []
        declared = foreign_key_columns(foreign_keys) | association_columns(resolved_models) |
                   macro_declared_columns(model_data)

        schema_data.each do |table_name, table|
          columns = table[:columns]

          columns.each do |col|
            next unless col[:name].end_with?("_id")

            indexed = SchemaConventions.lookup_indexed_columns(table).include?(col[:name])
            # Rails indexes a reference column when it creates it.
            next if %w[references belongs_to].include?(col[:type])
            next if indexed
            next unless declared.include?([ table_name.to_s, col[:name] ])

            # Check for polymorphic association (_type column alongside _id)
            base_name = col[:name].sub(/_id\z/, "")
            type_col = columns.find { |c| c[:name] == "#{base_name}_type" }

            if type_col
              # Polymorphic: need compound index on [type, id]
              compound_indexed = SchemaConventions.leading_index?(table[:indexes], [ "#{base_name}_type", "#{base_name}_id" ])
              unless compound_indexed
                missing << {
                  table: table_name,
                  column: "#{base_name}_type, #{base_name}_id",
                  polymorphic: true,
                  suggestion: "add_index #{SchemaConventions.source_symbol(table_name)}, [#{SchemaConventions.source_symbol("#{base_name}_type")}, #{SchemaConventions.source_symbol("#{base_name}_id")}]"
                }
              end
            else
              missing << {
                table: table_name,
                column: col[:name],
                suggestion: "add_index #{SchemaConventions.source_symbol(table_name)}, #{SchemaConventions.source_symbol(col[:name])}"
              }
            end
          end
        end

        missing
      end

      # Module.nesting inside the controller's body: a compact `class Admin::X` searches
      # itself alone, a nested one Admin too. Read as nested when the class is not found.
      def controller_nesting(record)
        declaration = DeclaredConstant.declaration_for(DeclaredConstant.declarations(record.source, path_name: record.path_name), record.path_name)
        return [ record.path_name, *SuperclassChain.nesting_of(record.path_name) ] unless declaration

        declaration.body_nesting
      end

      def detect_model_all_in_controllers(model_data)
        findings = []
        # The last segment, so Post.all is found inside module Admin for a compact `class Admin::Post`.
        model_names = model_data.map { |model| model[:name].to_s.split("::").last }

        return findings if model_names.empty?

        # One regex over every controller beats one AST walk per controller per
        # model, and a `Model.all` mention is all this heuristic needs. Regex
        # stays; the model names it looks for come from the model walk.
        escaped_names = model_names.uniq.map { |n| Regexp.escape(n) }
        combined_pattern = /(?<![\w:])((?:::)?(?:[A-Z]\w*::)*(?:#{escaped_names.join("|")}))\.all\b/
        models = model_data.to_h { |model| [ model[:name], model ] }

        SourceScan.each(root, kind: "app/controllers").each do |record|
          next unless record.source.include?(".all")

          nesting = controller_nesting(record)
          RubySource.code_only(record.source).scan(combined_pattern).each do |match|
            scopes = match[0].start_with?("::") ? [] : nesting
            # A nearer constant with a file of its own takes the name, model or not.
            found = SuperclassChain.resolve_in_scope(record.path_name, match[0], nesting: scopes) do |name|
              models.key?(name) ? name : (:other if ConcernPaths.find_file(root, name, outer: false))
            end
            next unless models.key?(found.to_s)

            model_name = found
            findings << {
              controller: record.file,
              model: model_name,
              suggestion: "#{model_name}.all loads all records into memory. Consider pagination or scoping."
            }
          end
        rescue StandardError
          next
        end

        findings
      end

      def detect_eager_load_candidates(model_data)
        # Find models with multiple has_many that are likely rendered together
        candidates = []
        model_data.each do |model|
          class_name = model[:name]
          has_many_assocs = model[:has_many].map { |a| a[:name] }

          next unless has_many_assocs.size >= 2

          candidates << {
            model: class_name,
            associations: has_many_assocs,
            suggestion: "Consider eager loading when rendering #{class_name} with associations: #{has_many_assocs.join(", ")}"
          }
        end

        candidates
      end

      SUMMARY_KEYS = %i[
        n_plus_one_risks missing_counter_cache missing_fk_indexes
        model_all_in_controllers eager_load_candidates
      ].freeze

      def build_summary(result)
        counts = SUMMARY_KEYS.to_h { |key| [ key, result[key].size ] }
        { total_issues: counts.values.sum }.merge(counts)
      end
    end
  end
end
