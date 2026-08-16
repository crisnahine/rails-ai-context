# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # The facts every context surface states about a Rails app, each rendered
    # in one place. Five serializers and three tools carried their own copy
    # of these lines; the copies drifted, and a warnings section that only
    # two of four generated files rendered made a half-failed run look clean
    # in the other two.
    module SectionFacts
      module_function

      def models_line(ctx)
        models = Payload.section(ctx, :models)
        models&.any? ? "- Models: #{models.size}" : nil
      end

      def database_line(ctx)
        schema = Payload.section(ctx, :schema)
        return nil unless SectionGuard.usable?(schema)

        "- Database: #{SchemaAdapter.label(ctx)} - #{CountPhrase.call(schema[:total_tables].to_i, "table")}"
      end

      def associations_list(model_data)
        (model_data[:associations] || [])
          .select { |a| a.is_a?(Hash) }
          .map { |a| "#{a[:type]} :#{a[:name]}" }
      end

      # Introspector failures, so a half-failed run cannot read as a clean
      # one in any generated file.
      def warnings(ctx)
        list = ctx.is_a?(Hash) ? ctx[:_warnings] : nil
        return [] if list.nil? || list.empty?

        lines = [ "", "## Warnings", "" ]
        list.each { |w| lines << "- **#{w[:introspector]}** skipped: #{w[:error]}" }
        lines
      end
    end
  end
end
