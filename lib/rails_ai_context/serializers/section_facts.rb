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
        models = Payload.models(ctx)
        models.any? ? "- Models: #{models.size}" : nil
      end

      def database_line(ctx)
        schema = Payload.section(ctx, :schema)
        return nil unless SectionGuard.usable?(schema)

        "- Database: #{SchemaAdapter.label(ctx)} - #{CountPhrase.call(schema[:total_tables].to_i, "table")}"
      end

      def auth_line(ctx)
        auth = Payload.section(ctx, :auth)
        return nil unless auth

        parts = []
        parts << "Devise" if auth.dig(:authentication, :devise)&.any?
        parts << "Rails 8 auth" if auth.dig(:authentication, :rails_auth)
        parts << "Pundit" if auth.dig(:authorization, :pundit)&.any?
        parts << "CanCanCan" if auth.dig(:authorization, :cancancan)
        parts.any? ? "- Auth: #{parts.join(' + ')}" : nil
      end

      def assets_line(ctx)
        assets = Payload.section(ctx, :assets)
        return nil unless assets

        # The pipeline introspector says "none" rather than nil, which reads as
        # a pipeline named none once it is joined with the rest.
        parts = [ assets[:pipeline], assets[:js_bundler], assets[:css_framework] ].compact
        parts.delete("none")
        parts.any? ? "- Assets: #{parts.join(', ')}" : nil
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
