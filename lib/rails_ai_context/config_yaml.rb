# frozen_string_literal: true

require "yaml"

module RailsAiContext
  # An app's config YAML read without running its ERB: string keys, and a failure
  # logged under the caller's label and answered as nil.
  module ConfigYaml
    ERB_OUTPUT = "RAC_ERB_OUTPUT"

    module_function

    # With `marker` an output tag reads as that marker, which marked? finds; without it, as empty.
    def read(root, file, label:, marker: nil)
      content = SafePath.read(file, under: root.to_s).first or return nil
      content = marker ? ErbSource.with_output_marked(content, marker) : ErbSource.without_tags(content)
      stringify_keys(YAML.safe_load(content, aliases: true, permitted_classes: [ Symbol ]))
    rescue StandardError, ScriptError => e
      RailsAiContext.debug_fail(e, nil, label: "#{label} #{file}")
    end

    def marked?(value)
      value.is_a?(String) && value.include?(ERB_OUTPUT)
    end

    def stringify_keys(value)
      case value
      when Hash then value.to_h { |key, inner| [ key.to_s.delete_prefix(":"), stringify_keys(inner) ] }
      when Array then value.map { |inner| stringify_keys(inner) }
      else value
      end
    end
  end
end
