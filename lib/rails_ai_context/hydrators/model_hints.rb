# frozen_string_literal: true

module RailsAiContext
  module Hydrators
    # Names in any casing to hints under the payload's spelling, deduped on
    # that spelling, with a warning only for a name nothing resolves. Both
    # hydrators compared the caller's spelling against the payload's and
    # warned about models they had just found.
    module ModelHints
      module_function

      # `describe` nil means a name that resolves to no model is simply not a
      # model: a controller names services, serializers and plain constants,
      # and every one of them read as a model the payload had lost.
      def resolve(names, context:, describe: nil)
        max = RailsAiContext.configuration.hydration_max_hints
        hints = {}
        warnings = []
        Array(names).uniq.each do |name|
          hint = SchemaHintBuilder.build(name, context: context)
          if hint
            hints[hint.model_name] ||= hint
          elsif describe
            warnings << describe.call(name)
          end
        end
        HydrationResult.new(hints: hints.values.first(max), warnings: warnings)
      end
    end
  end
end
