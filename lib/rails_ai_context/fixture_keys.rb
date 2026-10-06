# frozen_string_literal: true

require "date"
require "digest"
require "yaml"

module RailsAiContext
  # A fixture file's top-level keys are fixture names, with two exceptions.
  # ActiveRecord drops the shared-attribute anchor the fixtures guide writes as
  # DEFAULTS and its own _fixture key, so a generated `users(:DEFAULTS)` raises
  # "No fixture named". Every surface that reads those keys asks here.
  module FixtureKeys
    ANCHOR = "DEFAULTS"
    CONFIG = "_fixture"
    ERB_VALUE = "erb_value"

    # A label holding ERB_VALUE was computed by ERB, so its real names are unknown.
    def self.name?(key)
      key = key.to_s
      key != ANCHOR && !key.start_with?("_") && !key.include?(ERB_VALUE)
    end

    # The fixtures a file defines, label => attributes, or nil when it does not
    # read as fixtures. ERB is not run: a tag that prints becomes ERB_VALUE
    # and one that does not is dropped, so a file opening with
    # `<% digest = ... %>` still reads. Aliases are allowed, as Rails allows
    # them, and the labels `_fixture: ignore:` names are dropped. A result is
    # kept by content digest, so the introspector and the tool share a parse.
    def self.parse(content)
      key = Digest::SHA256.hexdigest(content.to_s)
      PARSED_MUTEX.synchronize { return PARSED[key] if PARSED.key?(key) }

      parsed = read(content)
      PARSED_MUTEX.synchronize do
        PARSED.clear if PARSED.size >= MAX_PARSED
        PARSED[key] = parsed
      end
    end

    PARSED = {}
    PARSED_MUTEX = Mutex.new
    MAX_PARSED = 512
    private_constant :PARSED, :PARSED_MUTEX, :MAX_PARSED

    def self.read(content)
      parsed = YAML.safe_load(without_erb(content), permitted_classes: [ Date, Time, Symbol ], aliases: true)
      return {} unless parsed
      return nil unless parsed.is_a?(Hash)

      config = parsed[CONFIG]
      ignored = config.is_a?(Hash) ? Array(config["ignore"]).map(&:to_s) : []
      parsed.each_with_object({}) do |(label, attributes), entries|
        label = label.to_s
        next if label == CONFIG || label == ANCHOR || ignored.include?(label) || !attributes.is_a?(Hash)

        entries[label] = attributes
      end.freeze
    rescue Psych::Exception, ArgumentError
      nil
    end

    def self.without_erb(content)
      content.to_s
        .gsub(/<%(?![=%]).*?%>/m, "")
        .gsub(/"<%=.*?%>"/m, %("#{ERB_VALUE}"))
        .gsub(/'<%=.*?%>'/m, "'#{ERB_VALUE}'")
        .gsub(/<%=.*?%>/m, ERB_VALUE)
    end
    private_class_method :read, :without_erb
  end
end
