# frozen_string_literal: true

module RailsAiContext
  # Wraps hydration output: hints for detected models + any warnings.
  HydrationResult = Data.define(:hints, :warnings) do
    def initialize(hints: [], warnings: [])
      super
    end

    def any?
      hints.any?
    end
  end
end
