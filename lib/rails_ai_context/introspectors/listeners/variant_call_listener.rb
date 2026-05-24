# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      class VariantCallListener < ChainedCallListener
        def initialize
          super(:variant)
        end
      end
    end
  end
end
