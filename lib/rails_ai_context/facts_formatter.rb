# frozen_string_literal: true

module RailsAiContext
  # Renders the schema facts summary shared by the rake task (ai:facts) and
  # the standalone CLI (rails-ai-context facts) so both outputs stay in sync.
  class FactsFormatter
    class << self
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
        schema = context[:schema]
        return [] unless schema.is_a?(Hash) && !schema[:error]

        tables = schema[:tables] || {}
        lines = [ "## Tables (#{tables.size})" ]
        tables.each do |name, meta|
          cols = meta[:columns]&.size || 0
          indexes = meta[:indexes]&.size || 0
          fks = meta[:foreign_keys]&.size || 0
          lines << "- #{name} (#{cols} #{cols == 1 ? 'col' : 'cols'}, " \
            "#{indexes} #{indexes == 1 ? 'index' : 'indexes'}, " \
            "#{fks} #{fks == 1 ? 'FK' : 'FKs'})"
        end
        lines << ""
        lines
      end

      def associations_section(context)
        models = context[:models]
        return [] unless models.is_a?(Hash) && !models[:error]

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
        gems = context[:gems]
        return [] unless gems.is_a?(Hash) && !gems[:error]

        notable = gems[:gems]&.select { |g| g[:category] != "other" }&.first(15)
        return [] unless notable&.any?

        lines = [ "## Key Dependencies" ]
        notable.each { |g| lines << "- #{g[:name]} (#{g[:category]})" }
        lines << ""
        lines
      end

      def architecture_section(context)
        conv = context[:conventions]
        return [] unless conv.is_a?(Hash) && !conv[:error]

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
