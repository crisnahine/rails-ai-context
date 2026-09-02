# frozen_string_literal: true

module RailsAiContext
  # Renders the schema facts summary shared by the rake task (ai:facts) and
  # the standalone CLI (rails-ai-context facts) so both outputs stay in sync.
  class FactsFormatter
    class << self
      include CountPhrase

      def render(context, inspect_hint: "rails ai:inspect")
        lines = []
        lines << "# #{app_name(context)} - Schema Facts"
        lines << "# Generated: #{Time.now.strftime('%Y-%m-%d %H:%M')}"
        lines << ""
        lines.concat(tables_section(context))
        lines.concat(associations_section(context))
        lines.concat(dependencies_section(context))
        lines.concat(architecture_section(context))
        lines << "---"
        lines << "Run `#{inspect_hint}` for full JSON introspection."
        lines.join("\n")
      end

      private

      def app_name(context)
        return context[:app_name] if context[:app_name]

        if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
          Rails.application.class.module_parent_name
        else
          "Rails App"
        end
      end

      def tables_section(context)
        schema = Payload.section(context, :schema)
        return [] unless schema

        tables = schema[:tables] || {}
        lines = [ "## Tables (#{tables.size})" ]
        tables.each do |name, meta|
          cols = meta[:columns]&.size || 0
          indexes = meta[:indexes]&.size || 0
          fks = meta[:foreign_keys]&.size || 0
          lines << "- #{name} (#{count_phrase(cols, "col")}, " \
            "#{count_phrase(indexes, "index", plural: "indexes")}, " \
            "#{count_phrase(fks, "FK", plural: "FKs")})"
        end
        lines << ""
        lines
      end

      def associations_section(context)
        models = Payload.models(context)
        return [] if models.empty?

        entries = models.filter_map do |model_name, meta|
          next unless meta.is_a?(Hash) && !meta[:error]

          assocs = meta[:associations] || []
          next if assocs.empty?

          grouped = assocs.group_by { |a| a[:type] || a["type"] }
          parts = grouped.map do |type, list|
            names = list.map { |a| a[:name] || a["name"] }
            "#{type} :#{names.join(', :')}"
          end
          "- #{model_name}: #{parts.join(' | ')}"
        end

        # "_none_" keeps the section honest instead of a bare dangling header
        entries = [ "_none_" ] if entries.empty?
        [ "## Associations" ] + entries + [ "" ]
      end

      def dependencies_section(context)
        notable = Payload.notable_gems(context).reject { |g| g[:category] == "other" }.first(15)
        return [] if notable.empty?

        lines = [ "## Key Dependencies" ]
        notable.each { |g| lines << "- #{g[:name]} (#{g[:category]})" }
        lines << ""
        lines
      end

      def architecture_section(context)
        conv = Payload.section(context, :conventions)
        return [] unless conv

        arch = conv[:architecture] || []
        return [] if arch.empty?

        lines = [ "## Architecture" ]
        arch.each { |a| lines << "- #{a}" }
        lines << ""
        lines
      end
    end
  end
end
