# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetModelDetails < BaseTool
      tool_name "rails_get_model_details"
      description "Get detailed information about a specific ActiveRecord model including associations, validations, scopes, enums, callbacks, and concerns. If no model specified, lists all available models with configurable detail level."

      input_schema(
        properties: {
          model: {
            type: "string",
            description: "Model class name (e.g. 'User', 'Post'). Omit to list all models."
          },
          detail: {
            type: "string",
            enum: %w[summary standard full],
            description: "Detail level for model listing. summary: names only. standard: names + association/validation counts (default). full: names + full association list. Ignored when specific model is given (always returns full)."
          },
          limit: {
            type: "integer",
            description: "Max models to return when listing. Default: 50."
          },
          offset: {
            type: "integer",
            description: "Skip this many models for pagination. Default: 0."
          }
        }
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(model: nil, detail: "standard", limit: nil, offset: 0, server_context: nil)
        models = cached_context[:models]
        return text_response("Model introspection not available. Add :models to introspectors.") unless models
        return text_response("Model introspection failed: #{models[:error]}") if models[:error]

        # Specific model — always full detail
        if model
          key = models.keys.find { |k| k.downcase == model.downcase } || model
          data = models[key]
          return text_response("Model '#{model}' not found. Available: #{models.keys.sort.join(', ')}") unless data
          return text_response("Error inspecting #{key}: #{data[:error]}") if data[:error]
          return text_response(format_model(key, data))
        end

        # Pagination
        total = models.size
        offset = [ offset.to_i, 0 ].max
        limit = normalize_limit(limit, 50)
        all_names = models.keys.sort
        paginated = all_names.drop(offset).first(limit)

        if paginated.empty? && total > 0
          return text_response("No models at offset #{offset}. Total: #{total}. Use `offset:0` to start over.")
        end

        pagination_hint = offset + limit < total ? "\n_Showing #{paginated.size} of #{total}. Use `offset:#{offset + limit}` for more._" : ""

        # Listing mode
        case detail
        when "summary"
          model_list = paginated.map { |m| "- #{m}" }.join("\n")
          text_response("# Available models (#{total})\n\n#{model_list}\n\n_Use `model:\"Name\"` for full detail._#{pagination_hint}")

        when "standard"
          lines = [ "# Models (#{total})", "" ]
          paginated.each do |name|
            data = models[name]
            next if data[:error]
            assoc_count = (data[:associations] || []).size
            val_count = (data[:validations] || []).size
            line = "- **#{name}**"
            line += " — #{assoc_count} associations, #{val_count} validations" if assoc_count > 0 || val_count > 0
            lines << line
          end
          lines << "" << "_Use `model:\"Name\"` for full detail, or `detail:\"full\"` for association lists._#{pagination_hint}"
          text_response(lines.join("\n"))

        when "full"
          lines = [ "# Models (#{total})", "" ]
          paginated.each do |name|
            data = models[name]
            next if data[:error]
            assocs = (data[:associations] || []).map { |a| "#{a[:type]} :#{a[:name]}" }.join(", ")
            line = "- **#{name}**"
            line += " (table: #{data[:table_name]})" if data[:table_name]
            line += " — #{assocs}" unless assocs.empty?
            lines << line
          end
          lines << "" << "_Use `model:\"Name\"` for validations, scopes, callbacks, and more._#{pagination_hint}"
          text_response(lines.join("\n"))

        else
          model_list = paginated.map { |m| "- #{m}" }.join("\n")
          text_response("# Available models (#{total})\n\n#{model_list}#{pagination_hint}")
        end
      end

      private_class_method def self.normalize_limit(limit, default)
        return default if limit.nil?
        val = limit.to_i
        val < 1 ? default : val
      end

      private_class_method def self.format_model(name, data)
        lines = [ "# #{name}", "" ]
        lines << "**Table:** `#{data[:table_name]}`" if data[:table_name]

        # File structure — compact one-line format
        structure = extract_model_structure(name)
        if structure
          lines << "**File:** `#{structure[:path]}` (#{structure[:total_lines]} lines)"
          map = structure[:sections].map { |s| "#{s[:label]}(#{s[:start]}-#{s[:end]})" }.join(" → ")
          lines << "**Structure:** #{map}"
        end

        # Associations
        if data[:associations]&.any?
          lines << "" << "## Associations"
          data[:associations].each do |a|
            detail = "- `#{a[:type]}` **#{a[:name]}**"
            detail += " (class: #{a[:class_name]})" if a[:class_name] && a[:class_name] != a[:name].to_s.classify
            detail += " through: #{a[:through]}" if a[:through]
            detail += " [polymorphic]" if a[:polymorphic]
            detail += " [optional]" if a[:optional]
            detail += " dependent: #{a[:dependent]}" if a[:dependent]
            lines << detail
          end
        end

        # Validations — compress repeated inclusion lists
        if data[:validations]&.any?
          lines << "" << "## Validations"
          # Track seen inclusion arrays to avoid repeating long lists
          seen_inclusions = {}
          data[:validations].each do |v|
            attrs = v[:attributes].join(", ")
            if v[:options]&.any?
              compressed_opts = v[:options].map do |k, val|
                if k.to_s == "in" && val.is_a?(Array) && val.size > 3
                  key = val.sort.join(",")
                  if seen_inclusions[key]
                    "#{k}: (same as #{seen_inclusions[key]})"
                  else
                    seen_inclusions[key] = attrs
                    "#{k}: #{val}"
                  end
                else
                  "#{k}: #{val}"
                end
              end
              opts = " (#{compressed_opts.join(', ')})"
            else
              opts = ""
            end
            lines << "- `#{v[:kind]}` on #{attrs}#{opts}"
          end
        end

        # Custom validate methods (business rules)
        if data[:custom_validates]&.any?
          lines << "- **Custom:** #{data[:custom_validates].map { |v| "`#{v}`" }.join(', ')}"
        end

        # Enums
        if data[:enums]&.any?
          lines << "" << "## Enums"
          data[:enums].each do |attr, values|
            lines << "- `#{attr}`: #{values.join(', ')}"
          end
        end

        # Scopes
        if data[:scopes]&.any?
          lines << "" << "## Scopes"
          lines << data[:scopes].map { |s| "- `#{s}`" }.join("\n")
        end

        # Callbacks
        if data[:callbacks]&.any?
          lines << "" << "## Callbacks"
          data[:callbacks].each do |type, methods|
            lines << "- `#{type}`: #{methods.join(', ')}"
          end
        end

        # Concerns — filter out framework/gem internal modules
        if data[:concerns]&.any?
          excluded_patterns = RailsAiContext.configuration.excluded_concerns
          app_concerns = data[:concerns].reject do |c|
            %w[Kernel JSON PP Marshal MessagePack].include?(c) ||
              excluded_patterns.any? { |pattern| c.match?(pattern) }
          end
          if app_concerns.any?
            lines << "" << "## Concerns"
            app_concerns.each do |c|
              methods = extract_concern_methods(c)
              if methods&.any?
                lines << "- **#{c}** — #{methods.join(', ')}"
              else
                lines << "- #{c}"
              end
            end
          end
        end

        # Class methods (e.g. Plan.free, Plan.pro)
        if data[:class_methods]&.any?
          lines << "" << "## Class methods"
          lines << data[:class_methods].first(15).map { |m| "- `#{m}`" }.join("\n")
        end

        # Key instance methods — include signatures from source if available
        if data[:instance_methods]&.any?
          lines << "" << "## Key instance methods"
          signatures = extract_method_signatures(name)
          if signatures&.any?
            signatures.first(15).each { |s| lines << "- `#{s}`" }
          else
            # Filter out association-generated methods (getters, setters, build_, create_)
            assoc_names = (data[:associations] || []).flat_map do |a|
              n = a[:name].to_s
              [ n, "#{n}=", "build_#{n}", "create_#{n}", "reload_#{n}", "reset_#{n}",
               "#{n}_ids", "#{n}_ids=", "#{n.singularize}_ids", "#{n.singularize}_ids=" ]
            end
            filtered = data[:instance_methods].reject { |m| assoc_names.include?(m) || m.end_with?("=") }
            if filtered.any?
              lines << filtered.first(15).map { |m| "- `#{m}`" }.join("\n")
            end
          end
        end

        lines.join("\n")
      end

      # Extract public method signatures (name + params) from model source
      private_class_method def self.extract_method_signatures(model_name)
        path = Rails.root.join("app", "models", "#{model_name.underscore}.rb")
        return nil unless File.exist?(path)
        return nil if File.size(path) > max_file_size

        source = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
        signatures = []
        in_private = false

        source.each_line do |line|
          in_private = true if line.match?(/\A\s*private\s*$/)
          next if in_private

          if (match = line.match(/\A\s*def\s+((?!self\.)[\w?!]+(?:\(([^)]*)\))?)/))
            name = match[1]
            signatures << name unless name.start_with?("initialize")
          end
        end

        signatures
      rescue
        nil
      end

      # Extract public method names from a concern's source file
      private_class_method def self.extract_concern_methods(concern_name)
        max_size = RailsAiContext.configuration.max_file_size
        underscore = concern_name.underscore
        # Search configurable concern paths
        path = RailsAiContext.configuration.concern_paths
          .map { |dir| Rails.root.join(dir, "#{underscore}.rb") }
          .find { |p| File.exist?(p) }
        return nil unless path
        return nil if File.size(path) > max_size

        source = File.read(path, encoding: "UTF-8", invalid: :replace, undef: :replace)
        methods = []
        in_private = false

        source.each_line do |line|
          in_private = true if line.match?(/\A\s*(private|protected)\s*$/)
          in_private = false if line.match?(/\A\s*public\s*$/)
          next if in_private

          if (match = line.match(/\A\s*def\s+([\w?!]+)/))
            methods << match[1] unless match[1].start_with?("_")
          end
        end

        methods.empty? ? nil : methods
      rescue
        nil
      end

      def self.max_file_size
        RailsAiContext.configuration.max_file_size
      end

      private_class_method def self.extract_model_structure(model_name)
        path = "app/models/#{model_name.underscore}.rb"
        full_path = Rails.root.join(path)
        return nil unless File.exist?(full_path)
        return nil if File.size(full_path) > max_file_size

        source_lines = File.readlines(full_path)
        sections = []
        current_section = nil
        current_start = nil

        source_lines.each_with_index do |line, idx|
          label = case line
          when /\A\s*class\s/ then "class definition"
          when /\A\s*(include|extend|prepend)\s/ then "includes"
          when /\A\s*[A-Z_]+\s*=/ then "constants"
          when /\A\s*(belongs_to|has_many|has_one|has_and_belongs_to_many)\s/ then "associations"
          when /\A\s*(validates|validate)\s/ then "validations"
          when /\A\s*scope\s/ then "scopes"
          when /\A\s*(enum|encrypts|normalizes|has_secure_password|has_one_attached|has_many_attached)\s/ then "macros"
          when /\A\s*(before_|after_|around_)/ then "callbacks"
          when /\A\s*def\s+self\./ then "class methods"
          when /\A\s*def\s/ then "instance methods"
          when /\A\s*private\s*$/ then "private"
          end

          if label && label != current_section
            sections << { start: current_start, end: idx + 1, label: current_section } if current_section
            current_section = label
            current_start = idx + 1
          end
        end
        sections << { start: current_start, end: source_lines.size, label: current_section } if current_section

        { path: path, total_lines: source_lines.size, sections: sections }
      rescue
        nil
      end
    end
  end
end
