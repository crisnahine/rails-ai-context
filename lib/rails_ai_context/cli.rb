# frozen_string_literal: true

module RailsAiContext
  # Explicit, not an implicit namespace from the directory alone. An implicit
  # one resolves through an autoload pointing at the directory, which only
  # works while Zeitwerk's `require` decoration is in place - and the
  # standalone binary rebuilds the gem environment before this constant is
  # first reached, which left a bare `require` of the directory raising
  # LoadError.
  module CLI
  end
end
