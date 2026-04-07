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

      # Introspect a file on disk (cached parse).
      def self.call(path)
        result = AstCache.parse(path)
        dispatch(result)
      end

      # Introspect a source string (no caching).
      def self.from_source(source)
        result = AstCache.parse_string(source)
        dispatch(result)
      end

      def self.dispatch(parse_result)
        dispatcher = Prism::Dispatcher.new
        listeners  = LISTENER_MAP.transform_values { |klass|
          listener = klass.new
          register_listener(dispatcher, listener)
          listener
        }

        dispatcher.dispatch(parse_result.value)

        listeners.transform_values(&:results)
      rescue => e
        $stderr.puts "[rails-ai-context] SourceIntrospector dispatch failed: #{e.message}" if ENV["DEBUG"]
        LISTENER_MAP.keys.each_with_object({}) { |key, h| h[key] = [] }
      end
      private_class_method :dispatch

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

        dispatcher.register(listener, *events) if events.any?
      end
      private_class_method :register_listener
    end
  end
end
