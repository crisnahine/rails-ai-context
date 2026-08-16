# frozen_string_literal: true

require "fileutils"
require "set"

module RailsAiContext
  module Install
    # Removing the context files of an AI tool the user dropped. All three
    # install entries prompt about this in their own voice; what they do once
    # the user says yes is the same work, and used to be three copies of it.
    module Cleanup
      module_function

      # @param tools [Array<Symbol>] the AI tools being dropped
      # @param keeping [Array<Symbol>] the tools still selected, whose files
      #   must survive even when a dropped tool names the same path
      # @param root [String, Pathname] project root
      # @return [Array<String>] the paths removed, directories marked with a
      #   trailing slash so callers can print them the way they always have
      def remove(tools:, keeping:, root:)
        kept = Array(keeping).flat_map { |key| AiTool.find(key)&.context_paths || [] }.to_set

        Array(tools).flat_map { |key|
          paths = AiTool.find(key)&.context_paths || []
          paths.filter_map { |relative| remove_path(relative, root) unless kept.include?(relative) }
        }
      end

      def remove_path(relative, root)
        full = File.join(root.to_s, relative)

        if File.directory?(full)
          FileUtils.rm_rf(full)
          "#{relative}/"
        elsif File.exist?(full)
          FileUtils.rm_f(full)
          relative
        end
      end
      private_class_method :remove_path
    end
  end
end
