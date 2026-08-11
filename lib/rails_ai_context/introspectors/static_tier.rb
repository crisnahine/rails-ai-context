# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # What an introspector can answer when the host app did not boot.
    # Extending this and declaring a kind is how an introspector becomes
    # reachable in the static tier; an undeclared one is a spec failure, so
    # "works statically but never said so" cannot be written.
    #
    # See docs/adr/0002-static-tier-declared-not-detected.md.
    module StaticTier
      # `call` runs unchanged against the static app handle.
      FILES_ONLY = :files_only
      # Needs live reflection; refuses honestly.
      RUNTIME_ONLY = :runtime_only
      # Answers from a different source through `static_call`.
      ALTERNATE_SOURCE = :alternate_source

      KINDS = [ FILES_ONLY, RUNTIME_ONLY, ALTERNATE_SOURCE ].freeze

      # One wording for "the app did not boot", carrying whatever the boot
      # failure said. Forked copies drift, and a single run then emits two
      # different explanations for the same condition.
      def self.unavailable_reason
        reason = RailsAiContext.static_reason
        base = "requires a booted Rails app"
        reason ? "#{base} (#{reason})" : base
      end

      def static_tier(kind = nil)
        return declared_static_tier if kind.nil?

        unless KINDS.include?(kind)
          raise ArgumentError, "#{self}: unknown static tier #{kind.inspect}, expected one of #{KINDS.join(', ')}"
        end

        @static_tier = kind
      end

      def static_tier_declared?
        !static_tier.nil?
      end

      def answers_statically?
        [ FILES_ONLY, ALTERNATE_SOURCE ].include?(static_tier)
      end

      # The declaration and the method have to agree, or the runner would call
      # something that does not exist, or skip one that does. Checked on demand
      # because the macro runs before the class body defines its methods.
      def validate_static_tier!
        kind = static_tier
        raise ArgumentError, "#{self} declares no static tier" if kind.nil?

        defines_static_call = method_defined?(:static_call) || private_method_defined?(:static_call)

        if kind == ALTERNATE_SOURCE && !defines_static_call
          raise ArgumentError, "#{self} declares #{kind} but defines no static_call"
        end

        if kind != ALTERNATE_SOURCE && defines_static_call
          raise ArgumentError, "#{self} declares #{kind} but defines static_call; declare alternate_source instead"
        end

        kind
      end

      private

      def declared_static_tier
        return @static_tier if defined?(@static_tier) && @static_tier
        superclass.static_tier if superclass.respond_to?(:static_tier)
      end
    end
  end
end
