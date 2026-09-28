# frozen_string_literal: true

module RailsAiContext
  module Serializers
    # Shared shape for the per-tool serializers that render a compact file by
    # default and hand off to a full-mode serializer when configured.
    #
    # Including classes inherit Serializers::Base for #context, and supply
    # #render_compact and #full_serializer_class.
    module ContextModeDispatch
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
