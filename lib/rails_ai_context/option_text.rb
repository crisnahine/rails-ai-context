# frozen_string_literal: true

module RailsAiContext
  # A String is the line the file holds, printed as written; anything else is a literal,
  # so `:published?` names a method where `published?` reads as an expression.
  module OptionText
    def self.call(value)
      value.is_a?(String) ? value : value.inspect
    end

    private

    def option_text(value)
      OptionText.call(value)
    end
  end
end
