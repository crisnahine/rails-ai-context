# frozen_string_literal: true

module RailsAiContext
  module Hydrators
    # Formats SchemaHint objects into Markdown for tool output.
    class HydrationFormatter
      # Format a HydrationResult into a Markdown section.
      def self.format(hydration_result)
        return "" unless hydration_result&.any?

        lines = [ "## Schema Hints", "" ]
        hydration_result.hints.each do |hint|
          lines << format_hint(hint)
          lines << ""
        end

        if hydration_result.warnings.any?
          hydration_result.warnings.each { |w| lines << "_#{w}_" }
          lines << ""
        end

        lines.join("\n")
      end

      # Format a single SchemaHint as a compact Markdown block.
      def self.format_hint(hint)
        lines = []
        lines << "### #{hint.model_name} #{hint.confidence}"
        lines << "**Table:** `#{hint.table_name}` (pk: `#{hint.primary_key}`)"

        if hint.columns.any?
          col_summary = hint.columns.first(10).map { |c|
            "`#{c[:name]}` #{c[:type]}#{c[:null] == false ? ' NOT NULL' : ''}"
          }
          col_summary << "... #{hint.columns.size - 10} more" if hint.columns.size > 10
          lines << "**Columns:** #{col_summary.join(', ')}"
        end

        if hint.associations.any?
          assoc_list = hint.associations.map { |a| "`#{a[:type]}` :#{a[:name]}" }
          lines << "**Associations:** #{assoc_list.join(', ')}"
        end

        if hint.validations.any?
          val_list = hint.validations.map { |v|
            attrs = v[:attributes]&.join(", ") || ""
            "#{v[:kind]}(#{attrs})"
          }
          lines << "**Validations:** #{val_list.join(', ')}"
        end

        lines.join("\n")
      end
    end
  end
end
