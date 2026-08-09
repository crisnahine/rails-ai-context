# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module RailsAiContext
  # Renders a count with its noun. Raw interpolation reads wrong at one
  # ("1 models"), and every tool and serializer that reports a count needs
  # the same fix, so they share this rather than each spelling it out.
  module CountPhrase
    # Pass `plural` where the inflector's answer is wrong for the domain:
    # database docs say indexes, not the inflector's indices.
    def self.call(count, noun, plural: nil)
      "#{count} #{count == 1 ? noun : plural || noun.pluralize}"
    end

    private

    # Mixed in for the classes; rake tasks and generators, which have no class
    # to mix into, call CountPhrase.call directly.
    def count_phrase(count, noun, plural: nil)
      CountPhrase.call(count, noun, plural: plural)
    end
  end
end
