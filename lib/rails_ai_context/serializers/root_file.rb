# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # The root context file, the same bytes whichever AI tool's path it lands at:
    # Copilot CLI keeps one copy of identical instruction files and every copy of
    # differing ones, and Cursor and VS Code read several of these paths at once.
    class RootFile < Base
      include StackOverviewHelper
      include CompactSerializerHelper

      def call
        RailsAiContext.configuration.context_mode == :full ? Full.new(context).call : render_compact_rules
      end

      class Full < MarkdownSerializer
        private

        def rules_section
          rules = [ "## Behavioral Rules", "", "When working in this codebase:" ]
          rules << "- Follow existing patterns and conventions detected above"
          rules << "- Use the database schema as the source of truth for column names and types"
          rules << "- Respect existing associations and validations when modifying models"
          arch = Payload.architecture(context)
          rules << "- Match the project's architecture style (#{arch.join(", ")})" if arch.any?
          rules << "- Run `#{detect_test_command}` after making changes to verify correctness"
          rules.join("\n")
        end
      end
    end
  end
end
