# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # The model list, rendered once at a density: :summary for the root file
    # (the most connected models), :listing for a rules file loaded beside the
    # models (one row per model), :full for the full-mode document. Every line
    # fits Budget::LINE_WIDTH, so a model with a hundred associations costs a
    # line, and rails_get_model_details answers the rest.
    #
    # Include where ToolGuideHelper and StackOverviewHelper are, for the tool
    # pointers and the app's own concerns.
    module ModelSection
      def model_rows(density)
        models = Payload.models(context)
        return [] if models.empty?

        case density
        when :summary then summary_rows(models)
        when :listing then listing_rows(models)
        when :full then models.flat_map { |name, data| full_rows(name, data) }
        else raise ArgumentError, "no model density #{density}"
        end
      end

      private

      def summary_rows(models)
        shown = Budget.cap(:key_models)
        rows = [ "## Key models (#{models.size} total, most connected first)" ]
        # A cut list reads as the whole one unless it says where the rest is.
        if served?("rails_get_model_details")
          rows << "_A list that ends in ...N more is cut: #{tool_ref("rails_get_model_details", 'model:"Name"', "model=Name")} has it whole._"
        end
        Payload.models_by_connection(models).first(shown).each do |name|
          data = models[name]
          next rows << SectionFacts.unread_row("- **#{name}**", data) if SectionFacts.unread_marker(data)

          counts = [ (count_phrase(data[:associations].size, "association") if data[:associations]&.any?),
                     (count_phrase(data[:validations].size, "validation") if data[:validations]&.any?) ].compact
          lead = "- **#{name}**#{" (#{counts.join(", ")})" if counts.any?}"
          associations = SectionFacts.associations_list(data)
          rows << (associations.any? ? Budget.list(associations, lead: "#{lead} - ") : lead)
          rows.concat(extras_rows(data))
        end
        rows << "- _...#{models.size - shown} more_" if models.size > shown
        rows << ""
      end

      def listing_rows(models)
        shown = Budget.cap(:listed_rows)
        schema = Payload.section(context, :schema)
        rows = models.keys.sort.first(shown).flat_map do |name|
          data = models[name]
          next [ SectionFacts.unread_row("- **#{name}**", data) ] if SectionFacts.unread_marker(data)

          note = SectionFacts.table_note(schema, data)
          table = note ? " (table #{note})" : (" (table: #{data[:table_name]})" if data[:table_name]).to_s
          associations = SectionFacts.associations_list(data)
          lead = "- **#{name}**#{table}"
          [ associations.any? ? Budget.list(associations, lead: "#{lead} - ") : lead, *extras_rows(data, concerns: true) ]
        end
        rows << "- ...#{count_phrase(models.size - shown, "more model")}" if models.size > shown
        rows.concat(tool_pointers([ "rails_get_model_details", 'model:"Name"', "model=Name", "for a model whole, with its concerns and callbacks resolved." ]))
      end

      def full_rows(name, data)
        rows = [ "### #{SectionFacts.escape_markdown(name)}" ]
        return rows << "- #{SectionFacts.unread_marker(data)}" if SectionFacts.unread_marker(data)

        note = SectionFacts.table_note(Payload.section(context, :schema), data)
        rows << "- Table: #{note || "`#{data[:table_name]}`"}" if note || data[:table_name]
        concerns = ConcernMembership.app_owned(data[:concerns], project_root)
        rows << Budget.list(concerns, lead: "- Concerns: ") if concerns.any?
        associations = SectionFacts.associations_list(data)
        rows << Budget.list(associations, lead: "- Associations: ") if associations.any?
        if data[:validations]&.any?
          validations = data[:validations].map { |v| [ v[:kind], SectionFacts.validation_target(v) ].reject(&:empty?).join(" ") }
          rows << Budget.list(validations, lead: "- Validations: ")
        end
        scopes = scope_names(Array(data[:scopes]))
        rows << Budget.list(scopes, lead: "- Scopes: ") if scopes.any?
        callbacks = data[:callbacks].is_a?(Hash) ? data[:callbacks] : {}
        callbacks.each do |kind, names|
          rows << Budget.list(Array(names).map { |n| n.is_a?(Hash) ? (n[:method] || n[:name]).to_s : n.to_s }, lead: "- Callbacks #{kind}: ", separator: "; ")
        end
        rows.concat(value_rows(data, "- ", label: "Enum "))
      end

      # Scopes, then the values an enum or a constant allows, a line each.
      def extras_rows(data, concerns: false)
        rows = []
        if concerns
          owned = ConcernMembership.app_owned(data[:concerns], project_root)
          rows << Budget.list(owned, lead: "  concerns: ") if owned.any?
        end
        scopes = scope_names(Array(data[:scopes]))
        rows << Budget.list(scopes, lead: "  scopes: ") if scopes.any?
        rows.concat(value_rows(data, "  "))
      end

      def value_rows(data, indent, label: "")
        enums = data[:enums].is_a?(Hash) ? data[:enums] : Array(data[:enums]).to_h { |enum| [ enum, nil ] }
        rows = enums.map do |attr, values|
          values ? Budget.list(SectionFacts.enum_names(values), lead: "#{indent}#{label}#{attr}: ") : "#{indent}#{label}#{attr}"
        end
        rows + Array(data[:constants]).grep(Hash).map { |c| Budget.list(Array(c[:values]), lead: "#{indent}#{c[:name]}: ") }
      end
    end
  end
end
