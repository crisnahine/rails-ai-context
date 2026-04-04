# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Static analysis for common performance anti-patterns:
    # N+1 query risks, missing counter_cache, Model.all in controllers,
    # missing foreign key indexes.
    class PerformanceIntrospector
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
          missing_fk_indexes: detect_missing_fk_indexes(schema_data),
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
        schema_path = File.join(root, "db/schema.rb")
        return {} unless File.exist?(schema_path)

        content = RailsAiContext::SafeFile.read(schema_path)
        return {} unless content
        tables = {}

        current_table = nil
        content.each_line do |line|
          if (match = line.match(/create_table\s+"(\w+)"/))
            current_table = match[1]
            tables[current_table] = { columns: [], indexes: [] }
          elsif current_table
            if (col = line.match(/t\.(\w+)\s+"(\w+)"/))
              tables[current_table][:columns] << { type: col[1], name: col[2] }
            elsif (ref = line.match(/t\.references\s+"(\w+)"/))
              tables[current_table][:columns] << { type: "references", name: "#{ref[1]}_id" }
            elsif (idx = line.match(/add_index\s+"#{Regexp.escape(current_table)}",\s+(?:"(\w+)"|\[([^\]]+)\])/))
              col_name = idx[1] || idx[2]&.gsub(/["'\s]/, "")
              tables[current_table][:indexes] << col_name
            elsif (tidx = line.match(/t\.index\s+\[([^\]]+)\]/))
              # t.index ["col_name"] inside create_table block
              cols = tidx[1].gsub(/["'\s]/, "").split(",")
              cols.each { |c| tables[current_table][:indexes] << c }
            end
          end

          if (idx = line.match(/add_index\s+"(\w+)",\s+(?:"(\w+)"|\[([^\]]+)\])/))
            table = idx[1]
            col_name = idx[2] || idx[3]&.gsub(/["'\s]/, "")
            tables[table][:indexes] << col_name if tables[table]
          end
        end

        tables
      end

      def load_model_data
        models_dir = File.join(root, "app/models")
        return [] unless Dir.exist?(models_dir)

        Dir.glob(File.join(models_dir, "**/*.rb")).filter_map do |path|
          content = RailsAiContext::SafeFile.read(path)
          next unless content&.match?(/< ApplicationRecord/)

          class_name = content.match(/class\s+(\w+)/)[1] rescue nil
          next unless class_name

          {
            name: class_name,
            file: path.sub("#{root}/", ""),
            has_many: content.scan(/has_many\s+:(\w+)(?:,\s*(.*))?/).map { |n, opts| { name: n, options: opts } },
            belongs_to: content.scan(/belongs_to\s+:(\w+)(?:,\s*(.*))?/).map { |n, opts| { name: n, options: opts } },
            includes_calls: content.scan(/\.includes\(([^)]+)\)/).flatten,
            scopes_with_includes: content.scan(/scope\s+:\w+.*\.includes\(/).any?,
            content: content
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

        controllers_dir = File.join(root, "app/controllers")
        return risks unless Dir.exist?(controllers_dir)

        view_contents = preload_view_contents
        model_lookup = model_data.each_with_object({}) { |m, h| h[m[:name]] = m }

        Dir.glob(File.join(controllers_dir, "**/*.rb")).each do |path|
          content = RailsAiContext::SafeFile.read(path)
          next unless content
          relative = path.sub("#{root}/", "")

          analyze_controller_n_plus_one(content, relative, model_lookup, view_contents, risks)
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
            model = model_lookup[model_name]
            next unless model

            full_chain = extract_query_chain(action_body, ivar)

            all_assocs = (model[:has_many] || []) + (model[:belongs_to] || [])
            all_assocs.each do |assoc|
              assoc_name = assoc[:name]
              # Skip polymorphic belongs_to — can't preload generically
              next if assoc[:options]&.match?(/polymorphic/)
              next unless association_accessed?(ivar, assoc_name, action_body, view_contents)

              risk = classify_n_plus_one_risk(full_chain, action_body, assoc_name)

              risks << {
                model: model_name,
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
        specific_re = /\.(#{PRELOAD_METHODS.join("|")})\(.*(:#{Regexp.escape(assoc_name)}\b|#{Regexp.escape(assoc_name)}:)/

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
          "#{model_name} query has preloading but missing :#{assoc_name} — add it to the includes list"
        when :low
          "#{assoc_name} is preloaded — no action needed"
        end
      end

      def detect_missing_counter_cache(model_data, schema_data)
        missing = []

        model_data.each do |model|
          model[:has_many].each do |assoc|
            assoc_name = assoc[:name]
            # Check if a counter_cache column exists but counter_cache isn't declared
            table_name = model[:name].underscore.pluralize
            count_col = "#{assoc_name}_count"

            table = schema_data[table_name]
            next unless table

            has_count_column = table[:columns].any? { |c| c[:name] == count_col }
            has_counter_cache = assoc[:options]&.include?("counter_cache")
            belongs_to_model = model_data.find { |m| m[:name] == assoc_name.classify }
            belongs_to_has_counter = belongs_to_model&.dig(:belongs_to)&.any? { |b|
              b[:options]&.include?("counter_cache")
            }

            # Flag: count column exists but counter_cache not declared on belongs_to side
            if has_count_column && !has_counter_cache && !belongs_to_has_counter
              missing << {
                model: model[:name],
                association: assoc_name,
                column: count_col,
                suggestion: "Add counter_cache: true to belongs_to :#{model[:name].underscore} in #{assoc_name.classify}"
              }
            end
          end
        end

        missing
      end

      def detect_missing_fk_indexes(schema_data)
        missing = []

        schema_data.each do |table_name, table|
          columns = table[:columns]

          columns.each do |col|
            next unless col[:name].end_with?("_id")

            indexed = table[:indexes].any? { |idx| idx.include?(col[:name]) }
            # References type auto-creates index in Rails
            next if col[:type] == "references"
            next if indexed

            # Check for polymorphic association (_type column alongside _id)
            base_name = col[:name].sub(/_id\z/, "")
            type_col = columns.find { |c| c[:name] == "#{base_name}_type" }

            if type_col
              # Polymorphic: need compound index on [type, id]
              compound_indexed = table[:indexes].any? { |idx|
                idx_str = idx.to_s
                idx_str.include?("#{base_name}_type") && idx_str.include?("#{base_name}_id")
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
        controllers_dir = File.join(root, "app/controllers")
        return findings unless Dir.exist?(controllers_dir)

        models_dir = File.join(root, "app/models")
        model_names = if Dir.exist?(models_dir)
          Dir.glob(File.join(models_dir, "**/*.rb")).filter_map do |path|
            content = RailsAiContext::SafeFile.read(path) or next
            match = content.match(/class\s+(\w+)\s*<\s*ApplicationRecord/)
            match[1] if match
          end
        else
          []
        end

        return findings if model_names.empty?

        # Build a single regex matching any model's .all call to avoid O(n*m) scanning
        escaped_names = model_names.map { |n| Regexp.escape(n) }
        combined_pattern = /(#{escaped_names.join("|")})\.all\b/

        Dir.glob(File.join(controllers_dir, "**/*.rb")).each do |path|
          content = RailsAiContext::SafeFile.read(path)
          next unless content
          relative = path.sub("#{root}/", "")

          content.scan(combined_pattern).each do |match|
            model_name = match[0]
            findings << {
              controller: relative,
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
        models_dir = File.join(root, "app/models")
        return candidates unless Dir.exist?(models_dir)

        Dir.glob(File.join(models_dir, "**/*.rb")).each do |path|
          content = RailsAiContext::SafeFile.read(path)
          next unless content&.match?(/< ApplicationRecord/)

          class_name = content.match(/class\s+(\w+)/)[1] rescue next
          has_many_assocs = content.scan(/has_many\s+:(\w+)/).flatten

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
