# frozen_string_literal: true

module RailsAiContext
  # The `detail` parameter shared by most tools. Values arrive over the wire as
  # strings, so this stays string-compatible rather than wrapping them; what it
  # adds is one definition of the allowed values, so callers ask this module
  # instead of comparing literals.
  module DetailLevel
    SUMMARY  = "summary"
    STANDARD = "standard"
    FULL     = "full"

    ALL     = [ SUMMARY, STANDARD, FULL ].freeze
    DEFAULT = STANDARD

    # The `detail` property tools publish in their input schema. Tools pass
    # their own wording and get the type and the enum from here, so the
    # advertised values and the normalizer cannot drift apart. Spelling the
    # values in a tool instead fails the enum-ownership spec.
    def self.schema(description)
      { type: "string", enum: ALL, description: description }
    end

    def self.valid?(detail)
      ALL.include?(detail.to_s)
    end

    # Unknown values read as the default rather than falling through to
    # whichever branch happens to be last.
    def self.normalize(detail)
      valid?(detail) ? detail.to_s : DEFAULT
    end

    def self.full?(detail)
      normalize(detail) == FULL
    end

    def self.summary?(detail)
      normalize(detail) == SUMMARY
    end
  end
end
