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

        content = File.read(schema_path, encoding: "UTF-8", invalid: :replace, undef: :replace)
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
          content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
          next unless content.match?(/< ApplicationRecord/)

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

      def detect_n_plus_one(model_data)
        risks = []

        # Check controllers for patterns like @model.association without includes
        controllers_dir = File.join(root, "app/controllers")
        return risks unless Dir.exist?(controllers_dir)

        # Pre-scan all view files once to avoid O(n*m*k) glob inside nested loop
        view_contents = preload_view_contents

        Dir.glob(File.join(controllers_dir, "**/*.rb")).each do |path|
          content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
          relative = path.sub("#{root}/", "")

          model_data.each do |model|
            model[:has_many].each do |assoc|
              model_ref = Regexp.escape(model[:name])
              pattern = /#{model_ref}\.(all|where|order|limit|find_each)\b/
              next unless content.match?(pattern)

              includes_pattern = /\.includes\(.*:#{Regexp.escape(assoc[:name])}/
              next if content.match?(includes_pattern)

              # Check pre-loaded views for association access
              assoc_pattern = /\.#{Regexp.escape(assoc[:name])}\b/
              next unless view_contents.any? { |vc| vc.match?(assoc_pattern) }

              risks << {
                model: model[:name],
                association: assoc[:name],
                controller: relative,
                suggestion: "Add .includes(:#{assoc[:name]}) to the query"
              }
            end
          end
        rescue StandardError
          next
        end

        risks.uniq { |r| [ r[:model], r[:association], r[:controller] ] }
      end

      def preload_view_contents
        views_dir = File.join(root, "app/views")
        return [] unless Dir.exist?(views_dir)

        Dir.glob(File.join(views_dir, "**/*.{erb,haml,slim}")).filter_map do |path|
          File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
        rescue StandardError
          nil
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
          table[:columns].each do |col|
            next unless col[:name].end_with?("_id")

            indexed = table[:indexes].any? { |idx| idx.include?(col[:name]) }
            # References type auto-creates index in Rails
            next if col[:type] == "references"
            next if indexed

            missing << {
              table: table_name,
              column: col[:name],
              suggestion: "add_index :#{table_name}, :#{col[:name]}"
            }
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
            content = File.read(path)
            match = content.match(/class\s+(\w+)\s*<\s*ApplicationRecord/)
            match[1] if match
          rescue => e
            $stderr.puts "[rails-ai-context] detect_model_all_in_controllers failed: #{e.message}" if ENV["DEBUG"]
            nil
          end
        else
          []
        end

        return findings if model_names.empty?

        # Build a single regex matching any model's .all call to avoid O(n*m) scanning
        escaped_names = model_names.map { |n| Regexp.escape(n) }
        combined_pattern = /(#{escaped_names.join("|")})\.all\b/

        Dir.glob(File.join(controllers_dir, "**/*.rb")).each do |path|
          content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
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
          content = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
          next unless content.match?(/< ApplicationRecord/)

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
