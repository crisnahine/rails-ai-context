# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Introspectors
    # Single-pass Prism AST introspector using the Dispatcher pattern.
    # Walks the AST once and feeds events to all registered listeners,
    # extracting associations, validations, scopes, enums, callbacks,
    # macros, and methods in a single tree traversal.
    #
    # Can be called with a file path (cached via AstCache) or a source string.
    class SourceIntrospector
      # Map result keys to listener classes. Iteration order is preserved
      # (Ruby >= 1.9), but results are accessed by key - never by index.
      LISTENER_MAP = {
        associations: Listeners::AssociationsListener,
        validations:  Listeners::ValidationsListener,
        scopes:       Listeners::ScopesListener,
        enums:        Listeners::EnumsListener,
        callbacks:    Listeners::CallbacksListener,
        macros:       Listeners::MacrosListener,
        methods:      Listeners::MethodsListener
      }.freeze

      # Introspect a file on disk (cached parse) with default listeners.
      def self.call(path)
        walk(path)
      end

      # Introspect a source string (no caching) with default listeners.
      def self.from_source(source)
        walk_source(source)
      end

      # Walk a file with a custom listener map. Returns { key => results_array }.
      def self.walk(path, listener_map = LISTENER_MAP)
        result = AstCache.parse(path)
        walk_dispatch(result, listener_map)
      end

      # Walk a source string with a custom listener map. Returns { key => results_array }.
      def self.walk_source(source, listener_map = LISTENER_MAP)
        result = AstCache.parse_string(source)
        walk_dispatch(result, listener_map)
      end

      def self.walk_dispatch(parse_result, listener_map)
        listeners  = listener_map.transform_values { |spec| spec.is_a?(Proc) ? spec.call : spec.new }
        dispatcher = ListenerRegistration.dispatcher_for(*listeners.values)

        dispatcher.dispatch(parse_result.value)

        listeners.transform_values(&:results)
      # A bad handler name is a programming error in a listener, not a parse
      # failure to shrug off; degrading it to empty results is the silence
      # this whole seam exists to end.
      rescue ListenerRegistration::UnknownEventError
        raise
      rescue => e
        $stderr.puts "[rails-ai-context] SourceIntrospector walk_dispatch failed: #{e.message}" if ENV["DEBUG"]
        listener_map.keys.each_with_object({}) { |key, h| h[key] = [] }
      end
      private_class_method :walk_dispatch
    end
  end
end
