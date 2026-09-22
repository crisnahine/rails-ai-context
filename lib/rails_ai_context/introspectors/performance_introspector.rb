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
    class PerformanceIntrospector
      extend StaticTier
      static_tier :files_only

      attr_reader :app

      def initialize(app)
        @app = app
      end

      def call
        schema_data = load_schema_data
        model_data = load_model_data

        {
          n_plus_one_risks: detect_n_plus_one(model_data),
          missing_counter_cache: detect_missing_counter_cache(model_data, schema_data),
          missing_fk_indexes: detect_missing_fk_indexes(schema_data, model_data, load_foreign_keys),
          model_all_in_controllers: detect_model_all_in_controllers,
          eager_load_candidates: detect_eager_load_candidates,
          summary: nil # populated below
        }.tap { |result| result[:summary] = build_summary(result) }
      rescue => e
        { error: e.message }
      end

      private

      def root
        app.root.to_s
      end

      def load_schema_data
        SchemaReader.for(root).tables
      end

      def load_foreign_keys
        SchemaReader.for(root).foreign_keys
      end

      def active_record_class_name(classes)
        classes.find { |c| c[:superclass] == "ApplicationRecord" }&.fetch(:name)
      end

      def declared_name(record)
        DeclaredConstant.resolve(record.source, record.path_name)
      end

      def load_model_data
        SourceScan.each(root, kind: "app/models").filter_map do |record|
          ast = SourceIntrospector.walk_source(record.source, {
            classes: Listeners::ClassDefinitionListener,
            associations: Listeners::AssociationsListener,
            includes: -> { Listeners::ChainedCallListener.new(:includes) }
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
            file: record.file,
            # This walk keeps no view of the other model files, so a
            # table_name_prefix declared by an enclosing module is out of
            # reach here and the stem stands alone. The declaration is looked
            # up by the qualified name the file writes, which is what a model
            # nested inside a module body is called.
            table_name: TableName.explicit(record.source, class_name) || TableName.stem(record.path),
            has_many: has_many,
            belongs_to: belongs_to,
            includes_calls: includes_calls
          }
        rescue => e
          $stderr.puts "[rails-ai-context] load_model_data failed: #{e.message}" if ENV["DEBUG"]
          nil
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

        Dir.glob(File.join(views_dir, "**/*.{erb,haml,slim}")).filter_map do |path|
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

      # Extract public action methods from controller source.
      # Returns Hash { "index" => "body...", "show" => "body..." }
      def extract_controller_actions(source)
        actions = {}
        current_action = nil
        current_lines = []
        in_private = false

        source.each_line do |line|
          if line.match?(/^\s*(private|protected)\s*$/)
            actions[current_action] = current_lines.join if current_action && !in_private
            current_action = nil
            current_lines = []
            in_private = true
            next
          end

          if (m = line.match(/^\s+def\s+(\w+)/))
            actions[current_action] = current_lines.join if current_action && !in_private
            current_action = m[1]
            current_lines = [ line ]
          elsif current_action
            current_lines << line
          end
        end

        actions[current_action] = current_lines.join if current_action && !in_private
        actions
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
        $stderr.puts "[rails-ai-context] app_written_counter_columns failed: #{e.message}" if ENV["DEBUG"]
        @app_written_counter_columns = Set.new
      end

      def detect_missing_counter_cache(model_data, schema_data)
        missing = []
        written = app_written_counter_columns

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
            next if written.include?(count_col)

            belongs_to_model = association_model(model_data, assoc)
            next unless belongs_to_model
            next if belongs_to_model[:belongs_to].any? { |b| b[:options].key?(:counter_cache) }

            inverse_name = options[:as] || model[:name].demodulize.underscore

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

      # The class an association declares is the one the app has;
      # `has_many :remarks, class_name: "Comment"` is answered by Comment, and
      # never by the Remark the name implies. When no model in the app answers
      # either, the row would name a file the reader cannot open, so it is not
      # written at all.
      def association_model(model_data, assoc)
        wanted = (assoc[:options][:class_name] || assoc[:name].classify).to_s
        model_data.find { |m| m[:name] == wanted } ||
          model_data.find { |m| m[:name].demodulize == wanted.demodulize }
      end

      # A `*_id` column is only a foreign key when something says so. An app
      # on uuid primary keys keeps `stripe_customer_id` and
      # `calendar_app_id` as external ids that cannot reference any row here,
      # and every one of them was reported as a missing index.
      # integer and bigint are one type for this purpose: an app that keeps a
      # bigint primary key may still declare an integer foreign key.
      def normalized_type(type)
        type.to_s == "bigint" ? "integer" : type.to_s
      end

      def primary_key_types(schema_data)
        schema_data.each_with_object(Set.new) do |(_name, table), types|
          Array(table[:columns]).each do |col|
            types << normalized_type(col[:type]) if col[:primary_key]
          end
        end
      end

      def foreign_key_columns(foreign_keys)
        Array(foreign_keys).each_with_object(Set.new) do |fk, found|
          column = fk[:column] || "#{fk[:to].to_s.singularize}_id"
          found << [ fk[:from].to_s, column.to_s ]
        end
      end

      def belongs_to_columns(model_data)
        Array(model_data).each_with_object(Set.new) do |model, found|
          table = model[:table_name].to_s
          next if table.empty?

          Array(model[:belongs_to]).each do |assoc|
            options = assoc[:options] || {}
            found << [ table, (options[:foreign_key] || "#{assoc[:name]}_id").to_s ]
          end
        end
      end

      def detect_missing_fk_indexes(schema_data, model_data = [], foreign_keys = [])
        missing = []
        pk_types = primary_key_types(schema_data)
        declared = foreign_key_columns(foreign_keys) | belongs_to_columns(model_data)

        schema_data.each do |table_name, table|
          columns = table[:columns]

          columns.each do |col|
            next unless col[:name].end_with?("_id")

            indexed = table[:indexes].any? { |idx| idx[:columns].include?(col[:name]) }
            # Rails indexes a reference column when it creates it.
            next if %w[references belongs_to].include?(col[:type])
            next if indexed

            # Check for polymorphic association (_type column alongside _id)
            base_name = col[:name].sub(/_id\z/, "")
            type_col = columns.find { |c| c[:name] == "#{base_name}_type" }

            if type_col
              # Polymorphic: need compound index on [type, id]
              compound_indexed = table[:indexes].any? { |idx|
                idx[:columns].include?("#{base_name}_type") && idx[:columns].include?("#{base_name}_id")
              }
              unless compound_indexed
                missing << {
                  table: table_name,
                  column: "#{base_name}_type, #{base_name}_id",
                  polymorphic: true,
                  suggestion: "add_index :#{table_name}, [:#{base_name}_type, :#{base_name}_id]"
                }
              end
            else
              next unless declared.include?([ table_name.to_s, col[:name] ]) ||
                          pk_types.include?(normalized_type(col[:type]))

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

      def detect_model_all_in_controllers
        findings = []
        model_names = SourceScan.each(root, kind: "app/models").filter_map do |record|
          ast = SourceIntrospector.walk_source(record.source, { classes: Listeners::ClassDefinitionListener })
          active_record_class_name(ast[:classes])
        end

        return findings if model_names.empty?

        # One regex over every controller beats one AST walk per controller per
        # model, and a `Model.all` mention is all this heuristic needs. Regex
        # stays; the model names it looks for come from the AST above.
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

      def detect_eager_load_candidates
        # Find models with multiple has_many that are likely rendered together
        candidates = []
        SourceScan.each(root, kind: "app/models").each do |record|
          ast = SourceIntrospector.walk_source(record.source, {
            classes: Listeners::ClassDefinitionListener,
            associations: Listeners::AssociationsListener
          })

          next unless active_record_class_name(ast[:classes])

          class_name = declared_name(record)
          has_many_assocs = ast[:associations]
            .select { |a| a[:type] == "has_many" }
            .map { |a| a[:name].to_s }

          next unless has_many_assocs.size >= 2

          candidates << {
            model: class_name,
            associations: has_many_assocs,
            suggestion: "Consider eager loading when rendering #{class_name} with associations: #{has_many_assocs.join(", ")}"
          }
        rescue => e
          $stderr.puts "[rails-ai-context] detect_eager_load_candidates failed: #{e.message}" if ENV["DEBUG"]
          next
        end

        candidates
      end

      def build_summary(result)
        total_issues = result[:n_plus_one_risks].size +
                       result[:missing_counter_cache].size +
                       result[:missing_fk_indexes].size +
                       result[:model_all_in_controllers].size +
                       result[:eager_load_candidates].size

        {
          total_issues: total_issues,
          n_plus_one_risks: result[:n_plus_one_risks].size,
          missing_counter_cache: result[:missing_counter_cache].size,
          missing_fk_indexes: result[:missing_fk_indexes].size,
          model_all_in_controllers: result[:model_all_in_controllers].size,
          eager_load_candidates: result[:eager_load_candidates].size
        }
      end
    end
  end
end
