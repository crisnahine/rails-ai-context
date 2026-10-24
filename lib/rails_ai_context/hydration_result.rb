# frozen_string_literal: true

module RailsAiContext
  # Wraps hydration output: hints for detected models.
  HydrationResult = Data.define(:hints) do
    def initialize(hints: [])
      super
    end

    def any?
      hints.any?
    end
  end
end
