# frozen_string_literal: true

module RailsAiContext
  # Floored, not rounded: a coverage figure rounded up to 100.0% claims completeness
  # beside the line saying one key is missing.
  module Percent
    module_function

    def floor(part, whole, decimals: 1)
      return 0 if whole.to_f.zero?

      scale = 10**decimals
      value = ((part.to_f / whole) * 100 * scale).floor / scale.to_f
      decimals.zero? ? value.to_i : value
    end
  end
end
