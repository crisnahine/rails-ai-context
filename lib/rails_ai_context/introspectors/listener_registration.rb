# frozen_string_literal: true

require "prism"

module RailsAiContext
  module Introspectors
    # Turns a listener into its own registration: every public `on_*_enter` /
    # `on_*_leave` method it answers to, inherited ones included, becomes a
    # registered event. Names are checked against the events the running prism
    # actually dispatches, so a typo raises here instead of never firing.
    #
    # See docs/adr/0001-own-listener-registration.md for why prism's own
    # register_public_methods is not used.
    module ListenerRegistration
      class UnknownEventError < RailsAiContext::Error; end

      # Deliberately wider than `on_<node>_(enter|leave)`: a typo'd suffix is
      # exactly the failure this module exists to catch, so anything shaped
      # like a handler is claimed here and then validated. Predicate and bang
      # methods cannot be event names, so they stay the listener's own.
      HANDLER_PATTERN = /\Aon_[a-z0-9_]+\z/

      class << self
        # A dispatcher with every listener wired. Validation runs for all of
        # them before any is registered, so a bad listener cannot leave a
        # half-wired dispatcher behind.
        def dispatcher_for(*listeners)
          plans = listeners.map { |listener| [ listener, events_for(listener) ] }

          Prism::Dispatcher.new.tap do |dispatcher|
            plans.each { |listener, events| dispatcher.register(listener, *events) if events.any? }
          end
        end

        # Register one listener onto an existing dispatcher. Returns the events.
        def register(dispatcher, listener)
          events_for(listener).tap do |events|
            dispatcher.register(listener, *events) if events.any?
          end
        end

        # The listener's handlers, sorted for a stable registration order.
        def events_for(listener)
          events = listener.public_methods.grep(HANDLER_PATTERN).sort

          unknown = events.reject { |event| known_event?(event) }
          unless unknown.empty?
            raise UnknownEventError,
                  "#{listener.class} defines #{unknown.join(', ')}, which prism #{Prism::VERSION} never dispatches"
          end

          events
        end

        def known_event?(event)
          known_events.include?(event.to_sym)
        end

        # Derived from the dispatcher itself: each `visit_x_node` it defines is
        # the source of an `on_x_node_enter` and an `on_x_node_leave` event.
        def known_events
          @known_events ||= Prism::Dispatcher.instance_methods(false).each_with_object(Set.new) { |method, set|
            next unless (name = method.to_s[/\Avisit_(.+)\z/, 1])
            set << :"on_#{name}_enter"
            set << :"on_#{name}_leave"
          }.freeze
        end
      end
    end
  end
end
