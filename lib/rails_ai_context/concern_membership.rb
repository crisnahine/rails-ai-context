# frozen_string_literal: true

module RailsAiContext
  # One answer to "which mixed-in modules count as this class's concerns",
  # in the payload sense CONTEXT.md pins. Five renderers each carried their
  # own filter set and they disagreed: one hid every namespaced concern, one
  # dropped the `excluded_concerns` config, and the two tiers of the
  # controller answer used different rules entirely.
  module ConcernMembership
    STDLIB = %w[Kernel JSON PP Marshal MessagePack].freeze
    FRAMEWORK_PREFIXES = %w[
      ActiveModel:: ActiveRecord:: ActiveSupport::
      ActionController:: ActionDispatch:: AbstractController::
    ].freeze
    # Rails defines these inside the model class itself, so no namespace rule
    # catches them.
    GENERATED = %w[GeneratedAssociationMethods GeneratedAttributeMethods].freeze

    module_function

    # The payload sense: a module in the ancestor chain that is part of the
    # class's story. Framework plumbing and the stdlib are not; a gem
    # capability module (Devise::Models::*, Turbo::Broadcastable) is.
    def payload?(name)
      return false if name.nil?

      name = name.to_s
      return false if STDLIB.any? { |p| name == p || name.start_with?("#{p}::") }
      return false if FRAMEWORK_PREFIXES.any? { |prefix| name.start_with?(prefix) }
      return false if GENERATED.any? { |g| name == g || name.end_with?("::#{g}") }

      RailsAiContext.configuration.excluded_concerns.none? { |pattern| name.match?(pattern) }
    end

    def payload(names)
      Array(names).select { |name| payload?(name) }
    end

    # Booted reading: the ancestor chain's non-class modules, through the
    # payload rule.
    def from_ancestors(klass)
      klass.ancestors
        .select { |mod| mod.is_a?(Module) && !mod.is_a?(Class) }
        .map(&:name)
        .compact
        .select { |name| payload?(name) }
    end

    # Static reading: only the mixins reflection would report (the listener's
    # ancestor flag), through the same rule, so both tiers answer alike.
    def from_mixins(mixins)
      Array(mixins)
        .select { |mixin| mixin[:ancestor] }
        .map { |mixin| mixin[:name] }
        .select { |name| payload?(name) }
        .uniq
    end

    # The narrower display sense: concerns the app itself defines, decided by
    # whether ConcernPaths can name their file.
    def app_owned(names, root)
      payload(names).select { |name| ConcernPaths.find_file(root.to_s, name) }
    end
  end
end
