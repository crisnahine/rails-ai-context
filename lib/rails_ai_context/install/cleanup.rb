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
      # @return [Hash] { removed: [paths], failed: [paths] }, directories
      #   marked with a trailing slash so callers can print them the way they
      #   always have. Both rm calls swallow their errors, so a path is only
      #   reported removed once it is gone.
      def remove(tools:, keeping:, root:)
        kept = Array(keeping).flat_map { |key| AiTool.find(key)&.context_paths || [] }.to_set
        removed = []
        failed = []

        Array(tools).each do |key|
          paths = AiTool.find(key)&.context_paths || []
          paths.each do |relative|
            next if kept.include?(relative)

            label, gone = remove_path(relative, root)
            next unless label

            (gone ? removed : failed) << label
          end
        end

        { removed: removed, failed: failed }
      end

      # @return [Array(String, Boolean), nil] the path's label and whether it
      #   is gone, or nil when there was nothing there to remove. A directory
      #   whose children went but which itself survives counts as not gone.
      def remove_path(relative, root)
        full = File.join(root.to_s, relative)

        if File.directory?(full)
          FileUtils.rm_rf(full)
          [ "#{relative}/", !File.exist?(full) ]
        elsif File.exist?(full)
          FileUtils.rm_f(full)
          [ relative, !File.exist?(full) ]
        end
      end
      private_class_method :remove_path
    end
  end
end
