# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # One answer to "which public methods are this class's own callable
    # interface". Five sites transcribed that question with five filter sets,
    # and each fix landed in one copy: the source paths ignored the listener's
    # owner field, so a class nested inside a controller contributed its
    # methods as actions, and the mailer path kept the pre-#136 reflection
    # answer that carries an app base class's public helpers in as actions.
    module ActionResolver
      # What bounds the ancestor walk and the reflection subtraction for each
      # kind: where the framework starts, and what the app's conventional base
      # class is called. Name checks first - the constants may not be loaded
      # in the process asking.
      KINDS = {
        controller: {
          framework: ->(k) {
            k.name.to_s.start_with?("ActionController::", "AbstractController::") ||
              (defined?(ActionController::Base) && k == ActionController::Base) ||
              (defined?(ActionController::API) && k == ActionController::API)
          },
          app_base: ->(k) {
            k.name == "ApplicationController" || k.name.to_s.end_with?("::ApplicationController")
          }
        },
        mailer: {
          framework: ->(k) {
            k.name.to_s.start_with?("ActionMailer::", "AbstractController::") ||
              (defined?(ActionMailer::Base) && k == ActionMailer::Base)
          },
          app_base: ->(k) {
            k.name == "ApplicationMailer" || k.name.to_s.end_with?("::ApplicationMailer")
          }
        }
      }.freeze

      module_function

      def framework?(klass, kind:)
        KINDS.fetch(kind)[:framework].call(klass)
      end

      def app_base?(klass, kind:)
        KINDS.fetch(kind)[:app_base].call(klass)
      end

      # Enclosing-class names as one constant path. Both nesting spellings
      # join to the same name (`class Admin::X` and `module Admin; class X`).
      def owner_name(method)
        Array(method[:owner]).join("::")
      end

      # The methods belonging to `class_name` itself, from one file's listener
      # output. A class nested inside the file is a separate owner, not part
      # of this class's interface.
      def own_methods(methods, class_name)
        expected = class_name.to_s
        Array(methods).select { |m| owner_name(m) == expected }
      end

      # The class's own public instance methods - the source-tier reading of
      # "actions". `skip_underscored` drops framework-shaped names.
      def own_actions(methods, class_name:, skip_underscored: true)
        names = own_methods(methods, class_name)
          .select { |m| m[:scope] == :instance && m[:visibility] == :public }
          .map { |m| m[:name] }
        names = names.reject { |name| name.start_with?("_") } if skip_underscored
        names.sort
      end

      def actions_from_source(source, class_name:, skip_underscored: true)
        walked = SourceIntrospector.walk_source(source, { methods: Listeners::MethodsListener })
        own_actions(walked[:methods] || [], class_name: class_name, skip_underscored: skip_underscored)
      rescue => e
        $stderr.puts "[rails-ai-context] ActionResolver.actions_from_source failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # The full booted chain: the class's own source first, then the nearest
      # app-owned ancestor that defines actions, then reflection with the base
      # subtraction - and an empty answer when every ancestor was readable and
      # none defines one, because reflection would only overwrite that answer
      # with helpers. `read_source` maps an ancestor class to its source, nil
      # when the app does not own the file.
      def resolve(klass, source:, kind:, read_source:)
        own = source ? actions_from_source(source, class_name: klass.name) : []
        return own if own.any?

        inherited, unreadable = inherited_actions(klass, kind: kind, read_source: read_source)
        return inherited if inherited.any?

        return reflected_actions(klass, kind: kind) if unreadable || source.nil?

        []
      rescue => e
        $stderr.puts "[rails-ai-context] ActionResolver.resolve failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # The nearest ancestor in the app that defines actions of its own.
      #
      # The walk stops at the app base by convention: it is where an app puts
      # the helpers every subclass shares, not actions, and reading it is what
      # produced the helpers-as-actions leak. Returns the actions and whether
      # the walk passed an ancestor whose source it could not read, which is
      # what tells an empty answer apart from one this app cannot see.
      def inherited_actions(klass, kind:, read_source:)
        unreadable = false
        k = klass.superclass
        while k&.name && !framework?(k, kind: kind) && !app_base?(k, kind: kind)
          src = read_source.call(k)
          if src
            actions = actions_from_source(src, class_name: k.name)
            return [ actions, unreadable ] if actions.any?
          else
            unreadable = true
          end
          k = k.superclass
        end
        [ [], unreadable ]
      end

      # `action_methods` subtracts inherited methods only as far as the
      # nearest abstract ancestor, which is the framework base. A class
      # mounted on the app's own base therefore arrives carrying every public
      # method that base and its concerns define; the base's own answer is
      # exactly that set, so subtracting it leaves what the class contributes.
      def reflected_actions(klass, kind:)
        actions = klass.action_methods.to_a.map(&:to_s)
        base = app_base_for(klass, kind: kind)
        actions -= base.action_methods.to_a.map(&:to_s) if base
        actions.sort
      end

      def app_base_for(klass, kind:)
        k = klass.superclass
        while k&.name && !framework?(k, kind: kind)
          return k if app_base?(k, kind: kind)
          k = k.superclass
        end
        nil
      end
    end
  end
end
