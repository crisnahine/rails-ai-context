# frozen_string_literal: true

module RailsAiContext
  module Install
    # The initializer guard's vocabulary, in one place. The generator wraps
    # and upgrades the guard and the doctor diagnoses it; each carried its own
    # copy of the pattern, and the copies had already been restated once.
    #
    # The bare form predates the respond_to? check: a path:/git: gemspec is
    # evaluated in-process by Bundler in every environment, defining a
    # VERSION-only stub `RailsAiContext` module even when the gem is not in
    # the current group - so `defined?(RailsAiContext)` alone does not prove
    # `.configure` exists.
    module InitializerFile
      BARE_GUARD = /^([ \t]*)if defined\?\(RailsAiContext\)$/
      CURRENT_GUARD = /^[ \t]*if defined\?\(RailsAiContext\)\s*&&\s*RailsAiContext\.respond_to\?\(:configure\)$/
      GUARD_LINE = "if defined?(RailsAiContext) && RailsAiContext.respond_to?(:configure)"
      CONFIGURE_CALL = /^[ \t]*RailsAiContext\.configure\b/
      GUARD_EXPRESSION = /defined\?\(\s*RailsAiContext\b|RailsAiContext\.respond_to\?\(\s*:configure\s*\)/

      module_function

      # What a guard is there to protect: a file that never calls into the gem
      # needs none.
      def configures?(content)
        content.match?(CONFIGURE_CALL)
      end

      def bare_guard?(content)
        content.match?(BARE_GUARD)
      end

      # Either form counts as guarded, so a re-run neither double-wraps an
      # initializer nor treats an unguarded one as guarded.
      def guarded?(content)
        content.match?(BARE_GUARD) || content.match?(CURRENT_GUARD)
      end

      # The two spellings this gem writes are not the only ones that work: a
      # hand-written `if RailsAiContext.respond_to?(:configure)` or an early
      # `return unless defined?(RailsAiContext)` protects the call just as
      # well. Anything that tests for the gem above the configure call counts,
      # so a report cannot call a safe file unguarded.
      def any_guard_before_configure?(content)
        index = content.index(CONFIGURE_CALL)
        return false unless index

        content[0, index].match?(GUARD_EXPRESSION)
      end
    end
  end
end
