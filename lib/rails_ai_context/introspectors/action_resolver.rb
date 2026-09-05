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
          app_base: ->(name) {
            name == "ApplicationController" || name.end_with?("::ApplicationController")
          }
        },
        mailer: {
          framework: ->(k) {
            k.name.to_s.start_with?("ActionMailer::", "AbstractController::") ||
              (defined?(ActionMailer::Base) && k == ActionMailer::Base)
          },
          app_base: ->(name) {
            name == "ApplicationMailer" || name.end_with?("::ApplicationMailer")
          }
        }
      }.freeze

      # The first `=` that assigns. `==`, `!=`, `>=`, `<=` and `=~` are reads
      # of the ivar on their left, and counting one as an assignment made
      # every guard clause look like a setter. A doubled bracket is the
      # shift-assign, which does assign.
      ASSIGNMENT = /(?<![=!<>~])=(?![=~])|(?<![<>])(?:<<|>>)=/

      module_function

      def framework?(klass, kind:)
        KINDS.fetch(kind)[:framework].call(klass)
      end

      def app_base?(klass, kind:)
        app_base_name?(klass.name, kind: kind)
      end

      def app_base_name?(name, kind:)
        KINDS.fetch(kind)[:app_base].call(name.to_s)
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
        own_actions(methods_in(source), class_name: class_name, skip_underscored: skip_underscored)
      rescue => e
        $stderr.puts "[rails-ai-context] ActionResolver.actions_from_source failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # The same reading with signatures, for the tools that show a file's
      # interface: an owner's public instance methods, its private ones, and
      # its class methods, each as written (`full_name(sep = ' ')`). The owner
      # defaults to the constant the file declares.
      def public_methods_from_source(source, owner: nil, skip_underscored: true)
        methods = own_methods_in(source, owner).select { |m| m[:scope] == :instance && m[:visibility] == :public }
        methods = methods.reject { |m| m[:name].start_with?("_") } if skip_underscored
        methods.map { |m| signature(m) }.uniq
      end

      def private_methods_from_source(source, owner: nil)
        own_methods_in(source, owner)
          .select { |m| m[:scope] == :instance && m[:visibility] != :public }
          .map { |m| signature(m) }.uniq
      end

      # A bare `private` never reaches `def self.x`; it does reach a def
      # inside `class_methods do` or `class << self`.
      def class_methods_from_source(source, owner: nil)
        own_methods_in(source, owner)
          .select { |m| m[:scope] == :class && (m[:visibility] == :public || m[:signature].to_s.start_with?("self.")) }
          .map { |m| signature(m) }.uniq
      end

      # The method as written, minus a `self.` receiver: `build(attrs)`.
      def signature(method)
        method[:signature].to_s.delete_prefix("self.")
      end

      # What sits between the parentheses, "" for a bare name.
      def parameter_list(method)
        signature(method)[/\A[^(]*\((.*)\)\z/m, 1].to_s
      end

      # One method's body out of a file's source, with the lines it occupies.
      # The `end` that closes a `def` sits at the `def`'s own indentation,
      # which reads more reliably than counting block depth.
      #
      # The name matches ignoring case, so an action asked for as "Show"
      # reaches `def show` here the way it does in the controller listing.
      def method_body(source, method_name)
        lines = source.to_s.lines
        start_idx = lines.index { |l| l.match?(/^\s*def\s+#{Regexp.escape(method_name.to_s)}\b/i) }
        return nil unless start_idx

        indent = lines[start_idx][/\A\s*/].length
        body = []
        end_idx = start_idx
        lines[start_idx..].each_with_index do |line, i|
          body << line.rstrip
          end_idx = start_idx + i
          break if i.positive? && line.match?(/\A\s{#{indent}}end\b/)
        end

        { code: body.join("\n"), start_line: start_idx + 1, end_line: end_idx + 1 }
      rescue => e
        $stderr.puts "[rails-ai-context] ActionResolver.method_body failed: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # What an action body assigns and what it renders. One owner for the
      # question, so a tool answers it from the source rather than from
      # another tool's rendered prose.
      #
      # Only the left of an assignment counts, which is what tells `@post =`
      # apart from a read of `@post` on the right and what makes
      # `@a, @b = x` two names.
      def assigned_ivars(action_source)
        action_source.to_s.each_line.flat_map do |line|
          split_at = line.index(ASSIGNMENT)
          next [] unless split_at

          line[0, split_at].scan(/@(\w+)/).flatten
        end.uniq
      end

      # A template the action renders instead of its own, `create` falling
      # back to `:new` being the case that matters.
      def rendered_templates(action_source)
        action_source.to_s.scan(/render\s+:(\w+)/).flatten.uniq
      end

      # An ivar a `render json:`/`render xml:` response consumes. There is no
      # template to cross-reference it against, so the call itself is the
      # only evidence it was used. `render json: @post.errors` counts `@post`.
      def rendered_ivars(action_source)
        action_source.to_s.scan(/render\s+(?:json|xml):\s*@(\w+)/).flatten.uniq
      end

      def methods_in(source)
        SourceIntrospector.walk_source(source, { methods: Listeners::MethodsListener })[:methods] || []
      end

      def own_methods_in(source, owner)
        methods = methods_in(source)
        own_methods(methods, owner || default_owner(source, methods))
      rescue => e
        $stderr.puts "[rails-ai-context] ActionResolver.own_methods_in failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      # The outermost owner the methods sit in: the file's class, or its
      # module when it is a concern or a helper, whichever a nested class sits
      # inside. With no methods at all, the first class the file declares.
      # Shortest owner path wins; two siblings at the same depth tie and the
      # one whose method comes first in the file is it.
      def default_owner(source, methods)
        methods.map { |m| Array(m[:owner]) }.reject(&:empty?).min_by(&:length)&.join("::") ||
          DeclaredConstant.declared_names(source).first ||
          ""
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

      # The same nearest-app-ancestor answer for a tier that has no classes:
      # the listing's own entries, walked by the parent name each carries. A
      # name the listing does not hold is the app base, a gem's controller or
      # the framework, and ends the walk.
      def inherited_actions_by_name(entries, parent_name, kind:, within: nil)
        seen = Set.new
        name = resolve_entry_name(entries, parent_name, within)
        while name && !seen.include?(name) && !app_base_name?(name, kind: kind)
          seen << name
          info = entries[name]
          return [] unless info.is_a?(Hash)

          actions = Array(info[:actions])
          return actions if actions.any?

          name = resolve_entry_name(entries, info[:parent_class], name)
        end
        []
      end

      # Ruby resolves a bare superclass from the enclosing namespace outward,
      # so `class Settings::ProfileController < BaseController` keys the
      # listing under Settings::BaseController. A name nothing resolves is
      # handed back as written, so the app-base check still sees it.
      def resolve_entry_name(entries, name, within)
        name = name&.to_s
        return name if name.nil? || within.nil? || entries.key?(name)

        scope = within.to_s.split("::")[0..-2]
        while scope.any?
          qualified = (scope + [ name ]).join("::")
          return qualified if entries.key?(qualified)

          scope.pop
        end
        name
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
