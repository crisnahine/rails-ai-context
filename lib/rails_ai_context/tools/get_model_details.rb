# frozen_string_literal: true

module RailsAiContext
  module Tools
    class GetModelDetails < BaseTool
      tool_name "rails_get_model_details"
      description "Get ActiveRecord model details: associations, validations, scopes, enums, callbacks, concerns. " \
        "Use when: understanding model relationships, adding validations, checking existing scopes/callbacks. " \
        "Specify model:\"User\" for full detail, or omit for a list. detail:\"full\" shows association lists."

      input_schema(
        properties: {
          model: {
            type: "string",
            description: "Model class name (e.g. 'User', 'Post'). Omit to list all models."
          },
          detail: RailsAiContext::DetailLevel.schema("Detail level for model listing. summary: names only. standard: names + association/validation counts (default). full: names + full association list. Ignored when specific model is given (always returns full)."),
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

      guide_row(
        order: 7,
        mcp: "rails_get_model_details(model:\"X\")",
        cli_args: "model=X",
        summary: "Associations, validations, scopes, enums, macros, delegations"
      )

      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      def self.call(model: nil, detail: "standard", limit: nil, offset: 0, server_context: nil)
        fetch_section(:models, subject: "Model introspection") do |models|
          # Specific model - always full detail (strip whitespace for fuzzy input)
          if model
            model = model.strip
            key = fuzzy_find_key(models.keys, model) || model
            data = models[key]
            unless data
              return not_found_response("Model", model, models.keys.sort,
                recovery_tool: "Call rails_get_model_details(detail:\"summary\") to see all models")
            end
            return text_response("Error inspecting #{key}: #{data[:error]}") if data[:error]
            return text_response(format_model(key, data))
          end

          # Pagination - sort by association count (most connected first)
          all_names = models.keys.sort_by { |m| -(models[m][:associations]&.size || 0) }
          page = paginate(all_names, offset: offset, limit: limit, default_limit: 50)
          paginated = page[:items]

          if paginated.empty? && page[:total] > 0
            return text_response(page[:hint])
          end

          pagination_hint = page[:hint].empty? ? "" : "\n#{page[:hint]}"

          # Listing mode
          case detail
          when "summary"
            model_list = paginated.map { |m| "- #{m}" }.join("\n")
            text_response("# Available models (#{page[:total]})\n\n#{model_list}\n\n_Use `model:\"Name\"` for full detail._#{pagination_hint}")

          when "standard"
            lines = [ "# Models (#{page[:total]})", "" ]
            paginated.each do |name|
              data = models[name]
              if data[:error]
                lines << unavailable_row(name, data)
                next
              end
              assoc_count = (data[:associations] || []).size
              val_count = (data[:validations] || []).size
              line = "- **#{name}**"
              line += " - #{count_phrase(assoc_count, "association")}, #{count_phrase(val_count, "validation")}" if assoc_count > 0 || val_count > 0
              lines << line
            end
            lines << "" << "_Use `model:\"Name\"` for full detail, or `detail:\"full\"` for association lists._#{pagination_hint}"
            text_response(lines.join("\n"))

          when "full"
            lines = [ "# Models (#{page[:total]})", "" ]
            paginated.each do |name|
              data = models[name]
              if data[:error]
                lines << unavailable_row(name, data)
                next
              end
              assocs = Serializers::SectionFacts.associations_list(data).join(", ")
              line = "- **#{name}**"
              line += " (table: #{data[:table_name]})" if data[:table_name]
              line += " - #{assocs}" unless assocs.empty?
              lines << line
            end
            lines << "" << "_Use `model:\"Name\"` for validations, scopes, callbacks, and more._#{pagination_hint}"
            text_response(lines.join("\n"))

          else
            model_list = paginated.map { |m| "- #{m}" }.join("\n")
            text_response("# Available models (#{page[:total]})\n\n#{model_list}#{pagination_hint}")
          end
        end
      end

      # How many methods a page lists, and how many the model has. The payload
      # caps its own list before this one does, so a reader who takes the page
      # for the model's whole interface is wrong twice over.
      LISTED_METHODS = 25

      private_class_method def self.methods_heading(shown, total)
        return "## Key instance methods" unless total.is_a?(Integer) && total > shown

        "## Key instance methods (#{shown} of #{total})"
      end

      private_class_method def self.unavailable_row(name, data)
        Serializers::SectionFacts.unread_row("- **#{name}**", data)
      end

      private_class_method def self.format_model(name, data)
        # Static-tier entries already carry [STATIC]; a runtime entry with a
        # resolved table is reflection-confirmed, hence [VERIFIED].
        header_tag = if data[:confidence]
          " #{data[:confidence]}"
        elsif data[:table_name] && !RailsAiContext.static_tier?
          " #{Confidence::VERIFIED}"
        else
          ""
        end
        lines = [ "# #{name}#{header_tag}", "" ]
        lines << "**Table:** `#{data[:table_name]}`" if data[:table_name]
        # A base class is not a concern, and the child may have no concerns at
        # all, so this stands outside that section.
        bases_unread = data[:bases_unread]
        lines << unread_bases_line(bases_unread) if bases_unread&.any?

        # File structure - compact one-line format
        structure = extract_model_structure(name)
        if structure
          lines << "**File:** `#{structure[:path]}` (#{count_phrase(structure[:total_lines], "line")})"
          map = structure[:sections].map { |s| "#{s[:label]}(#{s[:start]}-#{s[:end]})" }.join(" → ")
          lines << "**Structure:** #{map}"
        end

        # Schema columns - inline from schema introspection
        if data[:table_name]
          schema = Payload.section(cached_context, :schema)
          if schema && schema[:tables]&.key?(data[:table_name])
            table_data = schema[:tables][data[:table_name]]
            cols = table_data[:columns] || []
            if cols.any?
              lines << "" << "## Columns"
              cols.each do |c|
                parts = [ "**#{c[:name]}**", c[:type] ]
                parts << "NOT NULL" if c[:null] == false
                parts << "default: #{c[:default]}" if c[:default] && !c[:default].to_s.empty?
                parts << "array" if c[:array]
                lines << "- #{parts.join(' | ')}"
              end
            end
          end
        end

        # Mongoid documents have no AR table/columns - render declared fields
        # and embedded relations directly from the source-parsed macros instead.
        if data[:mongoid]
          if data[:fields]&.any?
            lines << "" << "## Fields"
            data[:fields].each do |f|
              type_str = f[:type] ? ": #{f[:type]}" : ""
              lines << "- `#{f[:name]}`#{type_str}"
            end
          end

          if data[:embeds]&.any?
            lines << "" << "## Embedded relations"
            data[:embeds].each do |e|
              lines << "- `#{e[:type]}` **#{e[:name]}**"
            end
          end
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
            detail += " (fk: #{a[:foreign_key]})" if a[:foreign_key] && a[:type] == "belongs_to"
            detail += " [UNAVAILABLE: #{a[:unavailable]}]" if a[:unavailable]
            lines << detail
          end
        end

        # Validations - compress repeated inclusion lists, deduplicate same kind+attribute
        if data[:validations]&.any?
          lines << "" << "## Validations"
          # Identify belongs_to association names for labeling implicit validations
          belongs_to_names = (data[:associations] || [])
            .select { |a| a[:type] == "belongs_to" && a[:optional] != true }
            .map { |a| a[:name] }
            .to_set

          # The options are part of the key: a model can validate one
          # attribute twice under different conditions, and the two rules are
          # different declarations, not a repeat of one.
          seen_validations = Set.new
          seen_inclusions = {}
          data[:validations].each do |v|
            dedup_key = [ v[:kind].to_s, v[:attributes].sort, v[:options] ]
            next if seen_validations.include?(dedup_key)
            seen_validations << dedup_key
            attrs = v[:attributes].join(", ")

            # Label implicit belongs_to presence validations
            implicit = v[:kind] == "presence" && v[:attributes].size == 1 && belongs_to_names.include?(v[:attributes].first)
            implicit_label = implicit ? " _(implicit from belongs_to)_" : ""

            if v[:options]&.any?
              # Filter out message: "required" from implicit belongs_to validations
              filtered_opts = v[:options].reject { |k, val| implicit && k.to_s == "message" && val.to_s == "required" }
              compressed_opts = filtered_opts.map do |k, val|
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
              opts = compressed_opts.any? ? " (#{compressed_opts.join(', ')})" : ""
            else
              opts = ""
            end
            lines << "- `#{v[:kind]}` on #{attrs}#{opts}#{implicit_label}"
          end
        end

        # Custom validate methods (business rules) - show method body when possible
        if data[:custom_validates]&.any?
          lines << "" << "## Validations" unless data[:validations]&.any?
          bodies = extract_custom_validate_bodies(name, data[:custom_validates])
          data[:custom_validates].each do |v|
            if bodies[v]
              lines << "- **Custom:** `#{v}` → #{bodies[v]}"
            else
              lines << "- **Custom:** `#{v}`"
            end
          end
        end

        # Enums
        if data[:enums]&.any?
          lines << "" << "## Enums"
          data[:enums].each do |attr, values|
            if values.is_a?(Hash)
              backing = values.values.first.is_a?(Integer) ? "integer" : "string"
              entries = values.map { |k, v| "#{k}(#{v})" }.join(", ")
              lines << "- `#{attr}`: #{entries} [#{backing}]"
            else
              lines << "- `#{attr}`: #{Array(values).join(', ')}"
            end
          end
        end

        # Scopes - show lambda body so AI can chain correctly. Each carries
        # the AST confidence: [VERIFIED] literal bodies vs [INFERRED] dynamic
        # expressions the parser can't fully resolve.
        if data[:scopes]&.any?
          lines << "" << "## Scopes"
          data[:scopes].each do |s|
            if s.is_a?(Hash)
              tag = s[:confidence] ? " #{s[:confidence]}" : ""
              lines << "- `#{s[:name]}` → #{s[:body]}#{tag}"
            else
              lines << "- `#{s}`"
            end
          end
        end

        # Callbacks
        if data[:callbacks]&.any?
          lines << "" << "## Callbacks"
          data[:callbacks].each do |type, methods|
            lines << "- `#{callback_type_label(type)}`: #{methods.map { |m| callback_target(m.to_s) }.join(', ')}"
          end
        end

        # Macros - surface hidden introspector data
        macro_lines = []
        macro_lines << "- `has_secure_password`" if data[:has_secure_password]
        macro_lines << "- `encrypts` #{data[:encrypts].map { |f| ":#{f}" }.join(', ')}" if data[:encrypts]&.any?
        macro_lines << "- `normalizes` #{data[:normalizes].map { |f| ":#{f}" }.join(', ')}" if data[:normalizes]&.any?
        macro_lines << "- `generates_token_for` #{data[:generates_token_for].map { |f| ":#{f}" }.join(', ')}" if data[:generates_token_for]&.any?
        macro_lines << "- `serialize` #{data[:serialize].map { |f| ":#{f}" }.join(', ')}" if data[:serialize]&.any?
        macro_lines << "- `store` #{data[:store].map { |f| ":#{f}" }.join(', ')}" if data[:store]&.any?
        macro_lines << "- `broadcasts` #{data[:broadcasts].join(', ')}" if data[:broadcasts]&.any?
        if data[:has_one_attached]&.any?
          macro_lines << "- `has_one_attached` #{data[:has_one_attached].map { |f| ":#{f}" }.join(', ')}"
        end
        if data[:has_many_attached]&.any?
          macro_lines << "- `has_many_attached` #{data[:has_many_attached].map { |f| ":#{f}" }.join(', ')}"
        end
        if macro_lines.any?
          lines << "" << "## Macros"
          lines.concat(macro_lines)
        end

        # Encryption details (expanded from encrypts)
        if data[:encryption_details]&.any?
          lines << "" << "## Encryption Details"
          data[:encryption_details].each do |ed|
            lines << "- #{encryption_detail_line(ed)}"
          end
        end

        # Normalizes details (expanded from normalizes)
        if data[:normalizes_details]&.any?
          lines << "" << "## Normalizes Details"
          data[:normalizes_details].each do |nd|
            lines << "- #{normalization_line(nd)}"
          end
        end

        # Token generation details
        if data[:token_generation]&.any?
          lines << "" << "## Token Generation"
          data[:token_generation].each do |tg|
            detail_str = tg.is_a?(Hash) ? "**#{tg[:purpose]}** (expires_in: #{tg[:expires_in] || 'default'})" : tg.to_s
            lines << "- #{detail_str}"
          end
        end

        # Delegations
        if data[:delegations]&.any?
          lines << "" << "## Delegations"
          data[:delegations].each do |d|
            lines << "- delegate #{d[:methods].map { |m| ":#{m}" }.join(', ')} to: :#{d[:to]}"
          end
        end
        lines << "- `delegate_missing_to` :#{data[:delegate_missing_to]}" if data[:delegate_missing_to]

        # Constants with value lists
        if data[:constants]&.any?
          lines << "" << "## Constants"
          data[:constants].each do |c|
            lines << "- `#{c[:name]}` = #{c[:values].join(', ')}"
          end
        end

        # The payload is already membership-filtered at the introspector seam
        # (ConcernMembership), so render it as-is. A model whose every concern
        # was hidden still reaches the section: the hidden count is the only
        # thing that says its declarations went somewhere.
        hidden = data[:concerns_hidden].to_i
        if data[:concerns]&.any? || hidden.positive?
          lines << "" << "## Concerns"
          Array(data[:concerns]).each do |c|
            methods = extract_concern_methods(c)
            if methods&.any?
              lines << "- **#{c}** - #{methods.join(', ')}"
            else
              lines << "- #{c}"
            end
          end
          unread = data[:concerns_unread]
          lines << unread_concerns_line(unread) if unread&.any?
          lines << "_#{count_phrase(hidden, "concern")} hidden by `excluded_concerns`._" if hidden.positive?
        end

        # Class methods - only show methods defined in the actual model file
        source_class_methods = extract_source_class_methods(name)
        if source_class_methods&.any?
          lines << "" << "## Class methods"
          source_class_methods.first(25).each { |m| lines << "- `#{m}`" }
        elsif data[:class_methods]&.any?
          # Fallback: filter obvious framework methods
          app_class_methods = data[:class_methods].reject { |m| m.match?(/\A(find_for_|find_or_|devise_|new_with_session|http_auth|params_auth|case_insensitive|expire_all|extend_remember|strip_whitespace|email_regexp|omniauth_providers)/) }
          if app_class_methods.any?
            lines << "" << "## Class methods"
            lines << app_class_methods.first(25).map { |m| "- `#{m}`" }.join("\n")
          end
        end

        # Key instance methods - only from source file, not framework-inherited
        source_instance_methods = extract_method_signatures(name)
        if source_instance_methods&.any?
          # Its own total, not the payload's: this branch lists the methods
          # the file declares, and the payload count includes the ones
          # reflection found on top of them.
          listed = source_instance_methods.first(LISTED_METHODS)
          lines << "" << methods_heading(listed.size, source_instance_methods.size)
          listed.each { |signature| lines << "- `#{signature}`" }
        elsif data[:instance_methods]&.any?
          # Fallback: filter association-generated and framework methods
          assoc_names = (data[:associations] || []).flat_map do |a|
            n = a[:name].to_s
            [ n, "#{n}=", "build_#{n}", "create_#{n}", "reload_#{n}", "reset_#{n}",
             "#{n}_ids", "#{n}_ids=", "#{n.singularize}_ids", "#{n.singularize}_ids=" ]
          end
          filtered = data[:instance_methods].reject { |m| assoc_names.include?(m) || m.end_with?("=") }
          if filtered.any?
            listed = filtered.first(LISTED_METHODS)
            # The heading counts one set: what this page prints, against the
            # list it printed from. The model's own total is a wider set - it
            # counts the association and writer methods filtered out here, and
            # everything past the payload's own cap - so it is said separately
            # rather than used as the denominator of a different number.
            lines << "" << methods_heading(listed.size, filtered.size)
            lines << listed.map { |m| "- `#{m}`" }.join("\n")
            total = data[:instance_method_count]
            if total.is_a?(Integer) && total > filtered.size
              lines << "_Reflection reports #{count_phrase(total, "instance method")} on #{name}; " \
                       "this list is what the payload carries, minus association and writer methods._"
            end
          end
        end

        # Cross-reference hints - guide AI to related tools
        hints = []
        hints << "`rails_get_schema(table:\"#{data[:table_name]}\")` for columns/indexes" if data[:table_name]
        controller_name = "#{name.pluralize}Controller"
        hints << "`rails_get_controllers(controller:\"#{controller_name}\")` for actions" if name.match?(/\A[A-Z][a-z]/)
        hints << "`rails_analyze_feature(feature:\"#{name}\")` for full-stack view"
        lines << "" << "_Next: #{hints.join(' | ')}_"

        lines.join("\n")
      end

      # The model's own file, not app/models/<underscored>.rb rebuilt from its
      # name - that misses a pack, an engine, and any inflection the app
      # registers.
      private_class_method def self.relative_model_path(model_name)
        RailsAiContext::Payload.model_file(cached_context, model_name)
      end

      # A carried path can name a gem rather than the app, and joining that to
      # the app root opens nothing. One reader answers both shapes.
      private_class_method def self.resolved_model_path(model_name)
        RailsAiContext::PortablePath.resolve(relative_model_path(model_name), rails_app.root.to_s)
      end

      # The macro's options are nested under an :options key. Printing that
      # hash leans on Hash#to_s, whose format changed in Ruby 3.4, so the
      # pairs are spelled here and an empty set drops the parenthesis.
      private_class_method def self.encryption_detail_line(ed)
        return ed.to_s unless ed.is_a?(Hash)

        pairs = ed.reject { |key, _| key == :field }.flat_map do |key, value|
          value.is_a?(Hash) ? value.map { |k, v| "#{k}: #{v}" } : "#{key}: #{value}"
        end

        pairs.any? ? "**#{ed[:field]}** (#{pairs.join(', ')})" : "**#{ed[:field]}**"
      end

      # A transformation the parser could not resolve is a marker, not the
      # name of a transformation, so it never follows the dash.
      private_class_method def self.normalization_line(nd)
        return nd.to_s unless nd.is_a?(Hash)

        transformation = nd[:transformation]
        return "**#{nd[:field]}** #{RailsAiContext::Confidence::INFERRED}" if transformation.nil? ||
          transformation == RailsAiContext::Confidence::INFERRED

        "**#{nd[:field]}** - #{transformation}"
      end

      # Extract bodies of custom validate methods (single-line or first meaningful line)
      private_class_method def self.extract_custom_validate_bodies(model_name, method_names)
        source = RailsAiContext::SafeFile.read(resolved_model_path(model_name))
        return {} unless source
        bodies = {}
        method_names.each do |name|
          # Find the method body
          if (match = source.match(/def\s+#{Regexp.escape(name)}\s*\n(.*?)(?=\n\s*end\b)/m))
            body_lines = match[1].lines.map(&:strip).reject(&:empty?)
            bodies[name] = body_lines.first&.truncate(120) if body_lines.any?
          end
        end
        bodies
      rescue => e
        RailsAiContext.debug_fail(e, {}, label: "extract_custom_validate_bodies")
      end

      # The model's own source, nil when the file is missing or too large.
      private_class_method def self.model_source(model_name)
        RailsAiContext::SafeFile.read(resolved_model_path(model_name))
      end

      private_class_method def self.extract_source_class_methods(model_name)
        source = model_source(model_name) or return nil
        methods = Introspectors::ActionResolver.class_methods_from_source(source, owner: model_name)
        methods.empty? ? nil : methods
      end

      private_class_method def self.extract_method_signatures(model_name)
        source = model_source(model_name) or return nil
        Introspectors::ActionResolver.public_methods_from_source(source, owner: model_name)
      end

      # On the booted tier reflection has already answered associations,
      # validations and enums for the concern, so the bare line overstates
      # what an unread file costs.
      private_class_method def self.unread_concerns_line(unread)
        "#{RailsAiContext::Confidence::UNAVAILABLE} #{count_phrase(unread.size, "concern")} " \
          "not read#{unread_gap_label}: #{unread.join(', ')}"
      end

      # Reflection inherits associations, validations and enums onto the child,
      # so an unread base costs the same keys an unread concern does.
      # The link to the next class up is written in the file the walk could not
      # open, so the static tier ends the chain there. The booted tier has the
      # class object and steps over it.
      private_class_method def self.unread_bases_line(unread)
        tail = RailsAiContext.static_tier? ? ". The static tier cannot follow the chain past a file it could not read" : ""
        "#{RailsAiContext::Confidence::UNAVAILABLE} #{count_phrase(unread.size, "base class")} " \
          "not read#{unread_gap_label}: #{unread.join(', ')}#{tail}"
      end

      private_class_method def self.unread_gap_label
        return "" if RailsAiContext.static_tier?

        keys = Introspectors::ModelIntrospector::MERGED_CONCERN_KEYS -
          Introspectors::ModelIntrospector::REFLECTED_CONCERN_KEYS
        " for #{keys.to_sentence(last_word_connector: " and ")}"
      end

      # Public method names from a concern's source file
      private_class_method def self.extract_concern_methods(concern_name)
        path = ConcernPaths.find_file(rails_app.root.to_s, concern_name)
        source = RailsAiContext::SafeFile.read(path)
        return nil unless source

        methods = Introspectors::ActionResolver.public_methods_from_source(source).map { |m| m.split("(").first }
        methods.empty? ? nil : methods
      end

      private_class_method def self.extract_model_structure(model_name)
        path = relative_model_path(model_name)
        full_path = resolved_model_path(model_name)
        source = RailsAiContext::SafeFile.read(full_path) or return nil

        source_lines = source.lines
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
      rescue => e
        RailsAiContext.debug_fail(e, nil, label: "extract_model_structure")
      end
    end
  end
end
