# frozen_string_literal: true

require "prism"
require "set"

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
        methods:      Listeners::MethodsListener,
        mixins:       Listeners::MixinsListener
      }.freeze

      # Receiverless calls outside any method (a class body, an `included do` block), by
      # name, each keeping its call sites so a called method reads their arguments.
      # `self_receiver:` counts `self.x = ...` too, a declaration written with a receiver.
      def self.calls_outside_methods(node, found = {}, self_receiver: false)
        return found if node.is_a?(Prism::DefNode)

        if node.is_a?(Prism::CallNode) && (node.receiver.nil? || (self_receiver && node.receiver.is_a?(Prism::SelfNode)))
          (found[node.name.to_s] ||= []) << node
        end
        node.child_nodes.compact.each { |child| calls_outside_methods(child, found, self_receiver: self_receiver) }
        found
      end

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

      # The calls a class body makes itself, out of what one walk found: a call
      # inside a `def` runs only when the method is called.
      def self.outside_defs(calls, methods)
        bodies = Array(methods).filter_map { |m| m[:offset]...m[:end_offset] if m[:offset] && m[:end_offset] }
        Array(calls).reject { |call| call[:offset] && bodies.any? { |range| range.cover?(call[:offset]) } }
      end

      # The calls a class body makes itself, out of a walk that ran MethodsListener as `methods:` and
      # NestedConstantsListener as `nested:`: a class or module it nests declares only for itself.
      def self.class_level(calls, walked)
        nested = Array(walked[:nested])
        outside_defs(calls, walked[:methods]).reject { |call| call[:offset] && nested.any? { |range| range.cover?(call[:offset]) } }
      end

      # Walk a parse result the caller already holds, so a second reader of the
      # same source does not parse it again.
      def self.walk_dispatch(parse_result, listener_map)
        listeners  = listener_map.transform_values { |spec| spec.is_a?(Proc) ? spec.call : spec.new }
        listeners.each_value { |listener| listener.comments = parse_result.comments }
        dispatcher = ListenerRegistration.dispatcher_for(*listeners.values)

        dispatcher.dispatch(parse_result.value)

        listeners.transform_values(&:results)
      # A bad handler name is a programming error in a listener, not a parse
      # failure to shrug off; degrading it to empty results is the silence
      # this whole seam exists to end.
      rescue ListenerRegistration::UnknownEventError
        raise
      rescue => e
        RailsAiContext.debug_fail(e, listener_map.keys.each_with_object({}) { |key, h| h[key] = [] }, label: "SourceIntrospector walk_dispatch")
      end
    end
  end
end
