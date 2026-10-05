# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    module Listeners
      # GenericMacroListener that also records the `if`/`unless`/`case` branches a macro sits under.
      # Apart, so the many walks that never read a condition do not pay for tracking branches.
      class ConditionalMacroListener < GenericMacroListener
        include BranchConditions

        private

        def macro_condition
          current_condition
        end
      end
    end
  end
end
