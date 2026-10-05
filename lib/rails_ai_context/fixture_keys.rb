# frozen_string_literal: true

require "date"
require "yaml"

module RailsAiContext
  # A fixture file's top-level keys are fixture names, with two exceptions.
  # ActiveRecord drops the shared-attribute anchor the fixtures guide writes as
  # DEFAULTS and its own _fixture key, so a generated `users(:DEFAULTS)` raises
  # "No fixture named". Every surface that reads those keys asks here.
  module FixtureKeys
    ANCHOR = "DEFAULTS"
    CONFIG = "_fixture"

    def self.name?(key)
      key = key.to_s
      key != ANCHOR && !key.start_with?("_")
    end

    # The fixtures a file defines, label => attributes, or nil when it does not
    # read as fixtures. ERB is not run: a tag that prints becomes "erb_value"
    # and one that does not is dropped, so a file opening with
    # `<% digest = ... %>` still reads. Aliases are allowed, as Rails allows
    # them, and the labels `_fixture: ignore:` names are dropped.
    def self.parse(content)
      parsed = YAML.safe_load(without_erb(content), permitted_classes: [ Date, Time, Symbol ], aliases: true)
      return {} unless parsed
      return nil unless parsed.is_a?(Hash)

      config = parsed[CONFIG]
      ignored = config.is_a?(Hash) ? Array(config["ignore"]).map(&:to_s) : []
      parsed.each_with_object({}) do |(label, attributes), entries|
        label = label.to_s
        next if label == CONFIG || label == ANCHOR || ignored.include?(label) || !attributes.is_a?(Hash)

        entries[label] = attributes
      end
    rescue Psych::Exception, ArgumentError
      nil
    end

    def self.without_erb(content)
      content.to_s
        .gsub(/<%(?![=%]).*?%>/m, "")
        .gsub(/"<%=.*?%>"/m, '"erb_value"')
        .gsub(/'<%=.*?%>'/m, "'erb_value'")
        .gsub(/<%=.*?%>/m, "erb_value")
    end
    private_class_method :without_erb
  end
end
