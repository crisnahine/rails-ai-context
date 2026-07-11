# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # One home for "can this introspector section be rendered?". A section
    # carrying :error (the introspector raised) or :unavailable (the data
    # source is absent) must be skipped, not rendered as empty-but-real data.
    module SectionGuard
      module_function

      def usable?(data)
        data.is_a?(Hash) && !data[:error] && !data[:unavailable]
      end
    end
  end
end
