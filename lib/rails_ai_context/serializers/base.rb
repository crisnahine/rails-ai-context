# frozen_string_literal: true

module RailsAiContext
  module Serializers
    class Base
      attr_reader :context

      def initialize(context)
        @context = context
      end
    end
  end
end
