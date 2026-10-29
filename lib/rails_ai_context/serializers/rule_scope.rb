# frozen_string_literal: true

require "json"

module RailsAiContext
  module Serializers
    # When an AI tool loads a scoped context file: every session, when the agent
    # touches a file one of the paths matches, or when the agent picks it by its
    # description. Each tool spells this in its own frontmatter.
    RuleScope = Data.define(:kind, :paths, :description) do
      def self.always(description) = new(kind: :always, paths: [], description: description)
      def self.paths(*paths, description:) = new(kind: :paths, paths: paths.flatten, description: description)
      def self.on_request(description) = new(kind: :on_request, paths: [], description: description)

      # The frontmatter lines and a blank one after them, or none where the tool
      # reads the scope from something else: a Claude rule with no paths loads
      # at launch, and OpenCode loads a nested AGENTS.md by its folder.
      def frontmatter(tool, name: nil, exclude_agent: nil)
        lines = case tool
        when :claude then claude
        when :cursor then cursor
        when :copilot then copilot(name, exclude_agent)
        when :opencode then []
        else raise ArgumentError, "no frontmatter for #{tool}"
        end
        lines.empty? ? lines : [ *lines, "" ]
      end

      private

      def claude
        case kind
        when :always then []
        when :paths then [ "---", "paths:", *listed, "---" ]
        else unsupported(:claude)
        end
      end

      def cursor
        case kind
        when :always then [ "---", "description: #{quoted(description)}", "alwaysApply: true", "---" ]
        when :paths then [ "---", "globs:", *listed, "alwaysApply: false", "---" ]
        else [ "---", "description: #{quoted(description)}", "alwaysApply: false", "---" ]
        end
      end

      # Copilot applies a file with no applyTo only when attached by hand.
      def copilot(name, exclude_agent)
        apply_to = case kind
        when :always then "**/*"
        when :paths then paths.join(",")
        else unsupported(:copilot)
        end
        lines = [ "---", "applyTo: #{quoted(apply_to)}", "name: #{quoted(name)}", "description: #{quoted(description)}" ]
        lines << "excludeAgent: #{quoted(exclude_agent)}" if exclude_agent
        lines << "---"
      end

      def listed
        paths.map { |path| "  - #{quoted(path)}" }
      end

      # A JSON string is a YAML double-quoted scalar.
      def quoted(value)
        JSON.generate(value.to_s)
      end

      def unsupported(tool)
        raise ArgumentError, "#{tool} has no #{kind} scope"
      end
    end
  end
end
