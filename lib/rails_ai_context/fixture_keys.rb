# frozen_string_literal: true

module RailsAiContext
  # A fixture file's top-level keys are fixture names, with two exceptions.
  # ActiveRecord drops the shared-attribute anchor the fixtures guide writes as
  # DEFAULTS and its own _fixture key, so a generated `users(:DEFAULTS)` raises
  # "No fixture named". Every surface that reads those keys asks here.
  module FixtureKeys
    ANCHOR = "DEFAULTS"

    def self.name?(key)
      key = key.to_s
      key != ANCHOR && !key.start_with?("_")
    end
  end
end
