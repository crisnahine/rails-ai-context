# frozen_string_literal: true

module RailsAiContext
  module Hydrators
    # Names in any casing to hints under the payload's spelling, deduped on
    # that spelling.
    module ModelHints
      module_function

      # A name that resolves to no model is simply not a model: a controller
      # names services and serializers, a view holds counts, hashes and presenters.
      def resolve(names, context:)
        max = RailsAiContext.configuration.hydration_max_hints
        hints = {}
        Array(names).uniq.each do |name|
          hint = SchemaHintBuilder.build(name, context: context)
          hints[hint.model_name] ||= hint if hint
        end
        HydrationResult.new(hints: hints.values.first(max))
      end
    end
  end
end
