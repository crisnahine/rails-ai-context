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

    # A label ERB printed into was computed, so its real names are unknown.
    def self.name?(key)
      key = key.to_s
      key != ANCHOR && !key.start_with?("_") && !ConfigYaml.marked?(key)
    end

    # label => attributes, or nil when not fixtures; ERB unrun, cached by digest so readers share a parse.
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
      parsed = YAML.safe_load(ErbSource.with_output_marked(content, ConfigYaml::ERB_OUTPUT), permitted_classes: [ Date, Time, Symbol ], aliases: true)
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
    private_class_method :read
  end
end
