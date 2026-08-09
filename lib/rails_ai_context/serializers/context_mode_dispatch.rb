# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Shared shape for the per-tool serializers that render a compact file by
    # default and hand off to a full-mode serializer when configured.
    #
    # Including classes supply #render_compact and #full_serializer_class.
    module ContextModeDispatch
      attr_reader :context

      def initialize(context)
        @context = context
      end

      def call
        if RailsAiContext.configuration.context_mode == :full
          full_serializer_class.new(context).call
        else
          render_compact
        end
      end
    end
  end
end
