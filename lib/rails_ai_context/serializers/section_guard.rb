# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # The serializers' name for the same question the tools ask through
    # Tools::SectionFetch. One definition, two call sites' vocabulary.
    module SectionGuard
      module_function

      def usable?(data)
        Tools::SectionFetch.usable?(data)
      end
    end
  end
end
