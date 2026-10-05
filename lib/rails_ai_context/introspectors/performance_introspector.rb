# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Static analysis for common performance anti-patterns:
    # N+1 query risks, missing counter_cache, Model.all in controllers,
    # missing foreign key indexes.
    #
    # Model and class structure is read from the AST. The N+1 detection below
    # deliberately stays on text: a risk is a correlation between a controller
    # action, a query chain and an association touched in an ERB view, and ERB
    # has no Ruby AST to walk. Matching both sides as text keeps them
    # comparable, and every finding here is a heuristic, not a fact.
    class PerformanceIntrospector < Base
      extend StaticTier
      static_tier :files_only

      # The run's sections so far; the models section answers which table a
      # model reads, so this section and the model tier never disagree.
      attr_writer :context

      def call
        schema_data = load_schema_data
        model_data = load_model_data

        {
          n_plus_one_risks: detect_n_plus_one(model_data),
          missing_counter_cache: detect_missing_counter_cache(model_data, schema_data),
          missing_fk_indexes: detect_missing_fk_indexes(schema_data, model_data, load_foreign_keys),
          model_all_in_controllers: detect_model_all_in_controllers(model_data),
          eager_load_candidates: detect_eager_load_candidates(model_data),
          summary: nil # populated below
        }.tap { |result| result[:summary] = build_summary(result) }
      end

      private

      def load_schema_data
        SchemaReader.for(root).tables
      end

      def load_foreign_keys
        SchemaReader.for(root).foreign_keys
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
            static = RailsAiContext.static_tier? || app.is_a?(RailsAiContext::StaticApp)
            static ? introspector.static_call : introspector.call
          end
        rescue StandardError => e
          RailsAiContext.debug_fail(e, {}, label: "resolved_models")
        end
      end

      # A hash lookup first: TableName.for_model_name scans every model, and
      # this runs once per model.
      def model_table(class_name)
        table_of(class_name, resolved_models)
      end

      def active_record_class_name(classes)
        classes.find { |c| c[:superclass] == "ApplicationRecord" }&.fetch(:name)
      end

      def declared_name(record)
        DeclaredConstant.resolve(record.source, record.path_name)
      end

      def load_model_data
        SourceScan.each(root, kind: :models).filter_map do |record|
          ast = SourceIntrospector.walk_source(record.source, {
            classes: Listeners::ClassDefinitionListener,
            associations: Listeners::AssociationsListener,
            includes: -> { Listeners::ChainedCallListener.new(:includes) },
            tree: TREE_LISTENER,
            mixins: Listeners::MixinsListener,
            counter_culture: -> { Listeners::GenericMacroListener.new(:counter_culture) }
          })

          # The listener names the class node alone, so the qualified name is
          # the one the app can resolve; the superclass check stays the guard
          # that this file holds a model at all.
          next unless active_record_class_name(ast[:classes])

          class_name = declared_name(record)

          has_many = ast[:associations].select { |a| a[:type] == "has_many" }.map do |a|
            { name: a[:name].to_s, options: a[:options] || {} }
          end

          belongs_to = ast[:associations].select { |a| a[:type] == "belongs_to" }.map do |a|
            { name: a[:name].to_s, options: a[:options] || {} }
          end

          includes_calls = ast[:includes].map { |h| h[:args].map(&:to_s).join(", ") }

          {
            name: class_name,
            # The name of the class node whose superclass is ApplicationRecord,
            # which is not always the qualified name above.
            ar_class_name: active_record_class_name(ast[:classes]),
            file: record.file,
            table_name: model_table(class_name),
            has_many: has_many,
            belongs_to: belongs_to,
            tree_parent_keys: tree_parent_keys(ast, class_name),
            counter_cultures: ast[:counter_culture].map { |c| counter_culture_record(c) },
            includes_calls: includes_calls
          }
        rescue => e
          RailsAiContext.debug_fail(e, nil, label: "load_model_data")
        end
      end

      # Gem macros that declare a parent key, with the option that renames it.
      # ponytail: a fixed list; a gem outside it declares keys the static walk cannot see.
      TREE_MACROS = { acts_as_tree: :foreign_key, acts_as_nested_set: :parent_column,
                      has_closure_tree: :parent_column_name }.freeze
      TREE_LISTENER = -> { Listeners::GenericMacroListener.new(*TREE_MACROS.keys) }
      TREE_CONCERN_LISTENERS = { tree: TREE_LISTENER, mixins: Listeners::MixinsListener }.freeze

      # The parent key a tree macro declares, in the model or its concerns.
      # The models section cannot carry it statically: the macro is a gem's.
      def tree_parent_keys(ast, class_name)
        collected, = ConcernMacros.collect(root, ast[:mixins], keys: %i[tree], prefer: "model",
                                           within: class_name, cache: (@concern_cache ||= {}),
                                           listeners: TREE_CONCERN_LISTENERS)
        (ast[:tree] + Array(collected[:tree])).map do |macro|
          ((macro[:options] || {})[TREE_MACROS[macro[:macro]]] || "parent_id").to_s
        end
      end

      LOOP_METHODS = %w[each map flat_map find_each each_with_object collect select reject
                        sort_by group_by each_slice each_with_index each_cons].freeze
      PRELOAD_METHODS = %w[includes eager_load preload].freeze
      QUERY_METHODS = %w[all where order limit find_each find_by_sql select joins left_joins].freeze

      def detect_n_plus_one(model_data)
        risks = []
        view_contents = preload_view_contents
        # The scan captures a single word, and a controller inside the model's
        # own namespace writes the bare name, so the lookup is keyed on it.
        model_lookup = model_data.group_by { |m| m[:name].demodulize }

        SourceScan.each(root, kind: "app/controllers").each do |record|
          analyze_controller_n_plus_one(record.source, record.file, model_lookup, view_contents, risks)
        rescue StandardError
          next
        end

        risks.uniq { |r| [ r[:model], r[:association], r[:controller], r[:action] ] }
      end

      def preload_view_contents
        views_dir = File.join(root, "app/views")
        return [] unless Dir.exist?(views_dir)

        Dir.glob(File.join(views_dir, RailsAiContext::ViewFile::MARKUP_GLOB)).filter_map do |path|
          RailsAiContext::SafeFile.read(path)
        end
      end

      # Analyze a single controller file for N+1 risks with risk classification.
      def analyze_controller_n_plus_one(content, controller_path, model_lookup, view_contents, risks)
        actions = extract_controller_actions(content)

        actions.each do |action_name, action_body|
          # Match @ivar = Model.chain where chain contains a query method anywhere
          # Handles Post.all, Post.includes(:user).all, Post.where(...).order(...), etc.
          action_body.scan(/@(\w+)\s*=\s*(\w+)\.[^\n]+/) do |ivar, model_name|
            chain = Regexp.last_match[0]
            query_re = /\.(#{QUERY_METHODS.map { |m| Regexp.escape(m) }.join("|")})\b/
            next unless chain.match?(query_re)
            model = resolve_bare_model(model_lookup[model_name], controller_path)
            next unless model

            full_chain = extract_query_chain(action_body, ivar)

            all_assocs = (model[:has_many] || []) + (model[:belongs_to] || [])
            all_assocs.each do |assoc|
              assoc_name = assoc[:name]
              # Skip polymorphic belongs_to - can't preload generically
              next if assoc[:options].key?(:polymorphic)
              next unless association_accessed?(ivar, assoc_name, action_body, view_contents)

              risk = classify_n_plus_one_risk(full_chain, action_body, assoc_name)

              risks << {
                model: model[:name],
                association: assoc_name,
                controller: controller_path,
                action: action_name,
                risk: risk.to_s,
                suggestion: n_plus_one_suggestion(risk, model_name, assoc_name)
              }
            end
          end
        end
      end

      # The scan captures a bare word, and two models can demodulize to it.
      # Rails would resolve it against the controller's own lexical scope,
      # outermost module last, so the file's directory breaks the tie. When
      # nothing there picks one, the row would name a model at random, so it
      # is not written at all.
      def resolve_bare_model(candidates, controller_path)
        candidates = Array(candidates)
        return candidates.first if candidates.size <= 1

        controller_scopes(controller_path).each do |scope|
          match = candidates.find { |m| m[:name].deconstantize == scope }
          return match if match
        end
        nil
      end

      # "app/controllers/admin/billing/invoices_controller.rb" reads as
      # ["Admin::Billing", "Admin", ""], the lexical scopes of the class in it.
      def controller_scopes(controller_path)
        parts = File.dirname(controller_path.to_s).split(File::SEPARATOR)
        parts = parts.drop(2) if parts.first(2) == %w[app controllers]
        parts.length.downto(0).map { |n| parts.first(n).join("/").camelize }
      end

      # Returns Hash { "index" => "body...", "show" => "body..." }
      def extract_controller_actions(source)
        ActionResolver.own_methods_in(source, nil)
          .select { |m| m[:scope] == :instance && m[:visibility] == :public }
          .to_h { |m| [ m[:name], ActionResolver.body_of(source, m)&.dig(:code).to_s ] }
      end

      # Extract the full query chain for an instance variable assignment.
      # Captures multi-line chains like:
      #   @posts = Post.where(published: true)
      #                .includes(:comments)
      #                .order(:created_at)
      def extract_query_chain(source, ivar)
        lines = source.lines
        result = +""
        capturing = false

        lines.each do |line|
          if line.match?(/@#{Regexp.escape(ivar)}\s*=/)
            capturing = true
            result << line
          elsif capturing
            # Continue capturing chained method calls (lines starting with .)
            if line.match?(/^\s*\./)
              result << line
            else
              break
            end
          end
        end

        result
      end

      # Check if an association is likely accessed in iteration context.
      def association_accessed?(ivar, assoc_name, action_body, view_contents)
        assoc_re = /\.#{Regexp.escape(assoc_name)}\b/

        # Controller: loop over collection + association access in the loop
        loop_re = /@#{Regexp.escape(ivar)}\.(#{LOOP_METHODS.join("|")})\b/
        return true if action_body.match?(loop_re) && action_body.match?(assoc_re)

        # Views: association accessed (render @collection implies iteration)
        view_contents.any? { |vc| vc.match?(assoc_re) }
      end

      # Classify risk based on preloading status in the query chain and action body.
      def classify_n_plus_one_risk(query_chain, action_body, assoc_name)
        combined = "#{query_chain}\n#{action_body}"
        preload_re = /\.(#{PRELOAD_METHODS.join("|")})\(/
        # Match both :assoc_name (symbol) and assoc_name: (hash key for nested includes)
        specific_re = /\.(#{PRELOAD_METHODS.join("|")})\(.*(:#{Regexp.escape(assoc_name)}\b|#{Regexp.escape(assoc_name)}:)/m

        if combined.match?(specific_re)
          :low
        elsif combined.match?(preload_re)
          :medium
        else
          :high
        end
      end

      def n_plus_one_suggestion(risk, model_name, assoc_name)
        case risk
        when :high
          "Add .includes(:#{assoc_name}) to the #{model_name} query to avoid N+1 queries"
        when :medium
          "#{model_name} query has preloading but missing :#{assoc_name} - add it to the includes list"
        when :low
          "#{assoc_name} is preloaded - no action needed"
        end
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

            record.source.scan(/(\w+_count)\s*[:=]/).each { |match| writers << match[0] }
          end
        end
        @app_written_counter_columns = writers
      rescue StandardError => e
        @app_written_counter_columns = RailsAiContext.debug_fail(e, Set.new, label: "app_written_counter_columns")
      end

      def detect_missing_counter_cache(model_data, schema_data)
        missing = []

        model_data.each do |model|
          model[:has_many].each do |assoc|
            options = assoc[:options]
            # A :through association reads its records over another one, so
            # there is no belongs_to on the far side to carry the counter.
            next if options.key?(:through)

            assoc_name = assoc[:name]
            count_col = "#{assoc_name}_count"

            table = schema_data[model[:table_name]]
            next unless table
            next unless table[:columns].any? { |c| c[:name] == count_col }
            next if options.key?(:counter_cache)
            next if app_written_counter_columns.include?(count_col)

            belongs_to_model = association_model(model_data, assoc, model[:name])
            next unless belongs_to_model
            next if belongs_to_model[:belongs_to].any? { |b| b[:options].key?(:counter_cache) }
            inverse_name = options[:as] || model[:name].demodulize.underscore
            next if counter_culture_keeps?(belongs_to_model, inverse_name, count_col)

            missing << {
              model: model[:name],
              association: assoc_name,
              column: count_col,
              suggestion: "Add counter_cache: true to belongs_to " \
                          ":#{inverse_name} in #{belongs_to_model[:name]}"
            }
          end
        end

        missing
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
            written = assoc[:class_name] || options[:class_name] || assoc[:name].to_s.camelize.singularize
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

      def tree_parent_columns(model_data)
        Array(model_data).each_with_object(Set.new) do |model, found|
          Array(model[:tree_parent_keys]).each { |key| found << [ model[:table_name].to_s, key ] }
        end
      end

      def table_of(class_name, models)
        details = models[class_name]
        ((details.is_a?(Hash) && details[:table_name]) || TableName.for_model_name(class_name, {})).to_s
      end

      def detect_missing_fk_indexes(schema_data, model_data = [], foreign_keys = [])
        missing = []
        declared = foreign_key_columns(foreign_keys) | association_columns(resolved_models) |
                   tree_parent_columns(model_data)

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
                  suggestion: "add_index :#{table_name}, [:#{base_name}_type, :#{base_name}_id]"
                }
              end
            else
              missing << {
                table: table_name,
                column: col[:name],
                suggestion: "add_index :#{table_name}, :#{col[:name]}"
              }
            end
          end
        end

        missing
      end

      def detect_model_all_in_controllers(model_data)
        findings = []
        model_names = model_data.map { |model| model[:ar_class_name] }

        return findings if model_names.empty?

        # One regex over every controller beats one AST walk per controller per
        # model, and a `Model.all` mention is all this heuristic needs. Regex
        # stays; the model names it looks for come from the model walk.
        escaped_names = model_names.map { |n| Regexp.escape(n) }
        combined_pattern = /(#{escaped_names.join("|")})\.all\b/

        SourceScan.each(root, kind: "app/controllers").each do |record|
          record.source.scan(combined_pattern).each do |match|
            model_name = match[0]
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
