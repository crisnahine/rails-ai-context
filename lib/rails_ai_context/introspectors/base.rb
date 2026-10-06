# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # The app handle every introspector is built with, and the app root as a
    # string. Subclasses declare their own static tier; this class declares none.
    class Base
      attr_reader :app

      def initialize(app)
        @app = app
      end

      private

      def root
        app.root.to_s
      end

      # The model files model_details lists, read; in either tier.
      def model_sources(skip_concerns: true, &block)
        SourceScan.each(root, kind: :models, skip_concerns: skip_concerns, base_model: model_base_check, &block)
      end

      def model_classes
        SourceScan.classes(root, kind: :models, base_model: model_base_check)
      end

      # Booted, a superclass the scan does not know may still be a record base a gem or initializer defines.
      def model_base_check
        method(:loaded_record_base?) unless app.is_a?(RailsAiContext::StaticApp) || !defined?(ActiveRecord::Base)
      end

      # The superclass as Ruby resolves it from the class's namespace outward.
      def loaded_record_base?(name, base)
        scopes = name.split("::")[0...-1]
        scopes.size.downto(0).any? do |depth|
          klass = loaded_constant([ *scopes.first(depth), *base.split("::") ])
          break klass < ActiveRecord::Base || false if klass.is_a?(Class)
        end
      rescue NameError
        false
      end

      # A constant the process already holds; a name still behind an autoload would run an app file to answer.
      def loaded_constant(segments)
        segments.reduce(Object) do |scope, segment|
          return unless scope.is_a?(Module) && scope.const_defined?(segment, false) && !scope.autoload?(segment, false)

          scope.const_get(segment, false)
        end
      end
    end
  end
end
