# frozen_string_literal: true

module RailsAiContext
  module Hydrators
    # Builds SchemaHint objects from cached introspection context.
    # Single point of truth for resolving a model name into a
    # structured hydration payload.
    class SchemaHintBuilder
      # Build a SchemaHint for a single model name.
      # Returns nil if the model is not found in context.
      def self.build(model_name, context:)
        models_data = context[:models]
        schema_data = context[:schema]
        return nil unless models_data.is_a?(Hash) && schema_data.is_a?(Hash)

        model_key = Payload.fuzzy_find_key(models_data.keys, model_name)
        return nil unless model_key

        model_info = models_data[model_key]
        return nil unless model_info.is_a?(Hash)

        table_name = model_info[:table_name]
        table_data = schema_data.dig(:tables, table_name) if table_name

        columns = if table_data
          (table_data[:columns] || []).map do |col|
            { name: col[:name], type: col[:type], null: col[:null] }.compact
          end
        else
          []
        end

        associations = (model_info[:associations] || []).map do |assoc|
          {
            name: assoc[:name],
            type: assoc[:type],
            class_name: assoc[:class_name],
            foreign_key: assoc[:foreign_key]
          }.compact
        end

        validations = (model_info[:validations] || []).map do |val|
          {
            kind: val[:kind],
            attributes: val[:attributes]
          }.compact
        end

        primary_key = table_data&.dig(:primary_key) || "id"

        # A static record already carries [STATIC]; a booted one has no
        # confidence key, and a resolved table there is reflection-confirmed.
        confidence = model_info[:confidence] || (table_data ? Confidence::VERIFIED : Confidence::INFERRED)

        SchemaHint.new(
          model_name: model_key.to_s,
          table_name: table_name.to_s,
          columns: columns,
          associations: associations,
          validations: validations,
          primary_key: primary_key.to_s,
          confidence: confidence
        )
      end
    end
  end
end
