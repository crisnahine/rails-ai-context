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
      # (Ruby >= 1.9), but results are accessed by key — never by index.
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
        result = AstCache.parse(path)
        walk_dispatch(result, LISTENER_MAP)
      end

      # Introspect a source string (no caching) with default listeners.
      def self.from_source(source)
        result = AstCache.parse_string(source)
        walk_dispatch(result, LISTENER_MAP)
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
        dispatcher = Prism::Dispatcher.new
        listeners  = listener_map.transform_values { |spec|
          listener = spec.is_a?(Proc) ? spec.call : spec.new
          register_listener(dispatcher, listener)
          listener
        }

        dispatcher.dispatch(parse_result.value)

        listeners.transform_values(&:results)
      rescue => e
        $stderr.puts "[rails-ai-context] SourceIntrospector walk_dispatch failed: #{e.message}" if ENV["DEBUG"]
        listener_map.keys.each_with_object({}) { |key, h| h[key] = [] }
      end
      private_class_method :walk_dispatch

      # Register a listener for all events it responds to.
      def self.register_listener(dispatcher, listener)
        events = []
        events << :on_call_node_enter  if listener.respond_to?(:on_call_node_enter)
        events << :on_def_node_enter   if listener.respond_to?(:on_def_node_enter)
        events << :on_singleton_class_node_enter if listener.respond_to?(:on_singleton_class_node_enter)
        events << :on_singleton_class_node_leave if listener.respond_to?(:on_singleton_class_node_leave)
        events << :on_class_node_enter  if listener.respond_to?(:on_class_node_enter)
        events << :on_class_node_leave  if listener.respond_to?(:on_class_node_leave)
        events << :on_module_node_enter if listener.respond_to?(:on_module_node_enter)
        events << :on_module_node_leave if listener.respond_to?(:on_module_node_leave)
        events << :on_block_node_enter  if listener.respond_to?(:on_block_node_enter)
        events << :on_block_node_leave  if listener.respond_to?(:on_block_node_leave)

        dispatcher.register(listener, *events) if events.any?
      end
      private_class_method :register_listener
    end
  end
end
