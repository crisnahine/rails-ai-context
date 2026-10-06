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

      # The first of the superclass's lexical candidates, innermost first, that is a loaded class.
      def loaded_record_base?(candidates)
        candidates.any? do |candidate|
          klass = loaded_constant(candidate.split("::"))
          break klass < ActiveRecord::Base || false if klass.is_a?(Class)
        end
      rescue NameError
        false
      end

      # A constant the process can reach without running the app's own code: an engine's
      # autoloaded model (ActiveStorage::Attachment) loads, even from vendor/bundle; an app file behind an autoload does not.
      def loaded_constant(segments)
        segments.reduce(Object) do |scope, segment|
          return unless scope.is_a?(Module) && scope.const_defined?(segment, false)

          pending = scope.autoload?(segment, false)
          pending = $LOAD_PATH.resolve_feature_path(pending)&.last || pending if pending && !File.absolute_path?(pending)
          return if pending && PathResolver.project_file?(pending, root) && !PortablePath.gem_file?(pending, root)

          scope.const_get(segment, false)
        end
      end
    end
  end
end
