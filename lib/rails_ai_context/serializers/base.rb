# frozen_string_literal: true

module RailsAiContext
  module Serializers
    class Base
      attr_reader :context

      # plan: the LoadPlan of the run, which a rules serializer reads to leave
      # out what a root file its AI tool reads already carries. Positional, so
      # a context passed as a bare hash (`new(tests: data)`) stays the context.
      def initialize(context, plan = nil)
        @context = context
        @plan = plan
      end
    end
  end
end
