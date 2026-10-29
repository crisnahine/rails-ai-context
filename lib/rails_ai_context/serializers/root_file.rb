# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # The root context file, the same bytes whichever AI tool's path it lands at:
    # Copilot CLI keeps one copy of identical instruction files and every copy of
    # differing ones, and Cursor and VS Code read several of these paths at once.
    class RootFile < Base
      include CompactSerializerHelper

      def call
        RailsAiContext.configuration.context_mode == :full ? MarkdownSerializer.new(context).call : render_compact_rules
      end
    end
  end
end
