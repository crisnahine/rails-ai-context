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

      module_function

      def bare_guard?(content)
        content.match?(BARE_GUARD)
      end

      # Either form counts as guarded, so a re-run neither double-wraps an
      # initializer nor treats an unguarded one as guarded.
      def guarded?(content)
        content.match?(BARE_GUARD) || content.match?(CURRENT_GUARD)
      end
    end
  end
end
