# frozen_string_literal: true

require "yaml"
require "fileutils"

module RailsAiContext
  module Install
    # Which AI tools the user picked, written and read the same way whichever
    # entry point ran. Two records exist because they answer to two owners:
    # the YAML file is the installer's own, and the initializer line is Rails
    # config a user hand-edits. The initializer therefore wins on read.
    #
    # Reading is a textual parse, never an eval or a boot, so the standalone
    # CLI can answer the question with no Rails in the process.
    module SelectionRecord
      YAML_FILE = ".rails-ai-context.yml"
      INITIALIZER = "config/initializers/rails_ai_context.rb"
      YAML_KEY = "ai_tools"

      # Matches the line the installer writes, and nothing else. Anchored past
      # any leading whitespace but not past a `#`, so the commented-out
      # default in the generated initializer is not mistaken for a selection.
      SELECTION_LINE = /^[ \t]*config\.ai_tools\s*=\s*%i\[([^\]]*)\]/

      module_function

      # @return [Array<Symbol>, nil] the recorded tools, or nil if none.
      def read(root:)
        from_initializer(root) || from_yaml(root)
      end

      def write(tools, root:)
        tools = normalize(tools)
        write_yaml(tools, root)
        write_initializer(tools, root)
        tools
      end

      def initializer_line(tools)
        "  config.ai_tools = %i[#{normalize(tools).join(' ')}]"
      end

      def from_initializer(root)
        path = File.join(root.to_s, INITIALIZER)
        return nil unless File.exist?(path)

        match = File.read(path).match(SELECTION_LINE)
        return nil unless match

        presence(normalize(match[1].split))
      rescue StandardError => e
        RailsAiContext.log_warn "[rails-ai-context] could not read #{INITIALIZER}: #{e.message}" if ENV["DEBUG"]
        nil
      end

      def from_yaml(root)
        path = File.join(root.to_s, YAML_FILE)
        return nil unless File.exist?(path)

        data = YAML.safe_load_file(path, permitted_classes: [ Symbol ]) || {}
        presence(normalize(data[YAML_KEY]))
      rescue StandardError => e
        RailsAiContext.log_warn "[rails-ai-context] could not read #{YAML_FILE}: #{e.message}" if ENV["DEBUG"]
        nil
      end

      # A name that is not a tool this gem knows would be written back out as
      # a selection nothing can act on.
      def normalize(tools)
        Array(tools).filter_map { |name| AiTool.find(name)&.key }
      end

      def presence(tools)
        tools.empty? ? nil : tools
      end

      def write_yaml(tools, root)
        path = File.join(root.to_s, YAML_FILE)
        data = File.exist?(path) ? (YAML.safe_load_file(path, permitted_classes: [ Symbol ]) || {}) : {}
        data[YAML_KEY] = tools.map(&:to_s)
        File.write(path, data.to_yaml)
      rescue StandardError => e
        RailsAiContext.log_warn "[rails-ai-context] could not write #{YAML_FILE}: #{e.message}"
        nil
      end

      # Only rewrites a line that is already there. Creating the initializer
      # is the generator's job, and a project without one is not a Rails app
      # this gem installed into.
      def write_initializer(tools, root)
        path = File.join(root.to_s, INITIALIZER)
        return nil unless File.exist?(path)

        content = File.read(path)
        return nil unless content.match?(SELECTION_LINE)

        File.write(path, content.sub(SELECTION_LINE, initializer_line(tools)))
      rescue StandardError => e
        RailsAiContext.log_warn "[rails-ai-context] could not write #{INITIALIZER}: #{e.message}"
        nil
      end
    end
  end
end
