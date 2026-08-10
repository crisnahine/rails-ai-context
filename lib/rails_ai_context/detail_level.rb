# frozen_string_literal: true

module RailsAiContext
  # The `detail` parameter shared by most tools. Values arrive over the wire as
  # strings, so this stays string-compatible rather than wrapping them; what it
  # adds is one definition of the allowed values and an ordering, so callers can
  # ask "is this at least standard?" instead of comparing literals.
  module DetailLevel
    SUMMARY  = "summary"
    STANDARD = "standard"
    FULL     = "full"

    ALL     = [ SUMMARY, STANDARD, FULL ].freeze
    DEFAULT = STANDARD

    ORDER = { SUMMARY => 0, STANDARD => 1, FULL => 2 }.freeze

    # The schema fragment tools declare, so the published enum and the
    # normalizer cannot drift apart. Spelling the values in a tool instead
    # fails the enum-ownership spec.
    SCHEMA_ENUM = ALL

    def self.schema_property(description)
      { type: "string", enum: SCHEMA_ENUM, description: description }
    end

    def self.valid?(detail)
      ALL.include?(detail.to_s)
    end

    # Unknown values read as the default rather than falling through to
    # whichever branch happens to be last.
    def self.normalize(detail)
      valid?(detail) ? detail.to_s : DEFAULT
    end

    def self.at_least?(detail, minimum)
      ORDER.fetch(normalize(detail)) >= ORDER.fetch(minimum)
    end

    def self.full?(detail)
      normalize(detail) == FULL
    end

    def self.summary?(detail)
      normalize(detail) == SUMMARY
    end
  end
end
